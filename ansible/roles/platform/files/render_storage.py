#!/usr/bin/env python3
"""Render the pinned local-path manifest without mutating the cached source.

The rendered manifest is a complete, self-contained manifest: the default
StorageClass annotation, the provisioner resources, and the digest-pinned
helper Pod image are applied here instead of by later kubectl patches.  The
output is written atomically only when its bytes change, and the script prints
exactly ``changed`` or ``unchanged`` so Ansible can report real idempotency.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import sys
import tempfile

import yaml

DEFAULT_CLASS_ANNOTATION = "storageclass.kubernetes.io/is-default-class"
PINNED_HELPER_PREFIX = "docker.io/library/busybox"


def _represent_string(dumper, value):
    # Emit embedded YAML/shell payloads as literal blocks instead of folded
    # quoted scalars, matching the upstream manifest's readable structure.
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


yaml.SafeDumper.add_representer(str, _represent_string)


class RenderError(Exception):
    """A deterministic, user-facing rendering failure."""


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Render the local-path manifest with local policy applied."
    )
    parser.add_argument("--source", required=True, help="checksum-verified source manifest")
    parser.add_argument("--output", required=True, help="rendered target manifest")
    parser.add_argument(
        "--resources-json",
        required=True,
        help="JSON object with requests/limits for the provisioner container",
    )
    parser.add_argument(
        "--helper-image",
        required=True,
        help="digest-pinned image for the helper Pod (tag@sha256:...)",
    )
    return parser.parse_args(argv)


def read_source(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        raise RenderError(f"cannot read source manifest {path}: {exc}") from exc
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RenderError(f"source manifest {path} is not valid UTF-8: {exc}") from exc
    return text, hashlib.sha256(raw).hexdigest()


def load_documents(text):
    try:
        documents = [doc for doc in yaml.safe_load_all(text) if doc is not None]
    except yaml.YAMLError as exc:
        raise RenderError(f"cannot parse source manifest: {exc}") from exc
    if not documents:
        raise RenderError("source manifest contains no YAML documents")
    for index, document in enumerate(documents):
        if not isinstance(document, dict):
            raise RenderError(f"document {index} is not a YAML mapping")
    return documents


def load_resources(raw):
    try:
        resources = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise RenderError(f"--resources-json is not valid JSON: {exc}") from exc
    if not isinstance(resources, dict):
        raise RenderError("--resources-json must be a JSON object")
    for section in ("requests", "limits"):
        values = resources.get(section)
        if not isinstance(values, dict) or not values:
            raise RenderError(f"--resources-json must contain a non-empty {section!r} object")
        for key, value in values.items():
            if not isinstance(value, (str, int, float)):
                raise RenderError(
                    f"resource {section}.{key} must be a string or number, "
                    f"got {type(value).__name__}"
                )
    return resources


def validate_helper_image(image):
    if not image:
        raise RenderError("--helper-image must not be empty")
    if "@sha256:" not in image:
        raise RenderError(
            "--helper-image must be digest-pinned as image:tag@sha256:<digest>; "
            "an implicit latest tag is not allowed"
        )
    if not image.startswith(PINNED_HELPER_PREFIX):
        raise RenderError(
            f"--helper-image must remain {PINNED_HELPER_PREFIX} (got {image!r})"
        )
    return image


def apply_storage_class(documents):
    found = 0
    for document in documents:
        if document.get("kind") != "StorageClass":
            continue
        metadata = document.setdefault("metadata", {})
        annotations = metadata.get("annotations") or {}
        annotations[DEFAULT_CLASS_ANNOTATION] = "true"
        metadata["annotations"] = annotations
        found += 1
    if not found:
        raise RenderError("source manifest has no StorageClass document")


def apply_resources(documents, resources):
    for document in documents:
        if document.get("kind") != "Deployment":
            continue
        spec = document.get("spec") or {}
        template = spec.get("template") or {}
        pod_spec = template.get("spec") or {}
        for container in pod_spec.get("containers") or []:
            if container.get("name") == "local-path-provisioner":
                container["resources"] = copy.deepcopy(resources)
                return
    raise RenderError("source manifest has no local-path-provisioner container")


def apply_helper_image(documents, helper_image):
    for document in documents:
        if document.get("kind") != "ConfigMap":
            continue
        if (document.get("metadata") or {}).get("name") != "local-path-config":
            continue
        data = document.get("data") or {}
        raw_helper = data.get("helperPod.yaml")
        if not raw_helper:
            raise RenderError("local-path-config ConfigMap has no helperPod.yaml data")
        try:
            helper = yaml.safe_load(raw_helper)
        except yaml.YAMLError as exc:
            raise RenderError(f"helperPod.yaml is not valid YAML: {exc}") from exc
        if not isinstance(helper, dict):
            raise RenderError("helperPod.yaml must contain a YAML mapping")
        pod_spec = helper.get("spec") or {}
        containers = pod_spec.get("containers") or []
        if not containers:
            raise RenderError("helperPod.yaml has no containers")
        for container in containers:
            container["image"] = helper_image
        data["helperPod.yaml"] = yaml.safe_dump(
            helper,
            sort_keys=False,
            default_flow_style=False,
            allow_unicode=True,
        )
        document["data"] = data
        return
    raise RenderError("source manifest has no local-path-config ConfigMap")


def render(documents):
    payload = yaml.safe_dump_all(
        documents,
        explicit_start=True,
        sort_keys=False,
        default_flow_style=False,
        allow_unicode=True,
    )
    if not payload.endswith("\n"):
        payload += "\n"
    return payload


def write_if_changed(output, payload):
    output = os.path.abspath(output)
    directory = os.path.dirname(output)
    os.makedirs(directory, exist_ok=True)
    try:
        with open(output, "r", encoding="utf-8", newline="") as handle:
            if handle.read() == payload:
                return False
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise RenderError(f"cannot read existing target {output}: {exc}") from exc

    fd, temporary = tempfile.mkstemp(prefix=".rendered-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
        os.chmod(temporary, 0o644)
        os.replace(temporary, output)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return True


def main(argv=None):
    args = parse_args(argv)
    source = os.path.abspath(args.source)
    output = os.path.abspath(args.output)
    if source == output:
        raise RenderError("--output must not point at the checksum-verified source manifest")

    source_text, source_digest = read_source(source)
    documents = load_documents(source_text)
    resources = load_resources(args.resources_json)
    helper_image = validate_helper_image(args.helper_image)

    apply_storage_class(documents)
    apply_resources(documents, resources)
    apply_helper_image(documents, helper_image)
    payload = render(documents)

    _, digest_after = read_source(source)
    if digest_after != source_digest:
        raise RenderError("source manifest changed during rendering; refusing to continue")

    changed = write_if_changed(output, payload)
    sys.stdout.write("changed\n" if changed else "unchanged\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RenderError as exc:
        sys.stderr.write(f"render_storage: {exc}\n")
        sys.exit(1)
