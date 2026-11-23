#!/usr/bin/env python3
"""Check custom resources against the openAPIV3Schema of the CRDs that ship with the same chart.

Usage: check_crd.py CRDS.json OBJECTS.json   (both JSON arrays; produce them with yq -o=json)
Covers what decides an apply here: type, required, enum, properties, items, minItems/maxItems.
Unknown fields are errors (like kubectl/server-side apply strict field validation), unless the schema
says x-kubernetes-preserve-unknown-fields. Standard library only, so CI needs no extra package.
"""
import json
import sys

TYPES = {"object": dict, "array": list, "string": str, "boolean": bool}


def check(value, schema, path, errors):
    kind = schema.get("type")
    if schema.get("x-kubernetes-int-or-string"):
        if not isinstance(value, (int, str)) or isinstance(value, bool):
            errors.append(f"{path}: int-or-string 필요")
        return
    if kind in TYPES and not isinstance(value, TYPES[kind]):
        errors.append(f"{path}: {kind} 필요, {type(value).__name__}")
        return
    if kind == "integer" and (not isinstance(value, int) or isinstance(value, bool)):
        errors.append(f"{path}: integer 필요")
        return
    if kind == "number" and (not isinstance(value, (int, float)) or isinstance(value, bool)):
        errors.append(f"{path}: number 필요")
        return
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: 허용 값 {schema['enum']}")
    if isinstance(value, dict):
        props = schema.get("properties")
        for name in schema.get("required", []):
            if name not in value:
                errors.append(f"{path}.{name}: 필수")
        for name, item in value.items():
            if props is not None and name in props:
                check(item, props[name], f"{path}.{name}", errors)
            elif isinstance(schema.get("additionalProperties"), dict):
                check(item, schema["additionalProperties"], f"{path}.{name}", errors)
            elif props is not None and not schema.get("x-kubernetes-preserve-unknown-fields"):
                errors.append(f"{path}.{name}: 스키마에 없는 필드")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: 최소 {schema['minItems']}개")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path}: 최대 {schema['maxItems']}개")
        for i, item in enumerate(value):
            check(item, schema.get("items", {}), f"{path}[{i}]", errors)


def schemas(crds):
    found = {}
    for crd in crds:
        if not crd or crd.get("kind") != "CustomResourceDefinition":
            continue
        spec = crd["spec"]
        for version in spec["versions"]:
            found[(spec["group"], version["name"], spec["names"]["kind"])] = version["schema"]["openAPIV3Schema"]
    return found


def validate(crds, objects):
    known = schemas(crds)
    errors, checked = [], 0
    for obj in objects:
        if not obj or "/" not in obj.get("apiVersion", ""):
            continue
        group, version = obj["apiVersion"].split("/", 1)
        schema = known.get((group, version, obj["kind"]))
        if schema is None:
            continue
        checked += 1
        body = {k: v for k, v in obj.items() if k not in ("apiVersion", "kind", "metadata")}
        props = {k: v for k, v in schema.get("properties", {}).items() if k not in ("apiVersion", "kind", "metadata")}
        check(body, dict(schema, properties=props), f"{obj['kind']}/{obj['metadata']['name']}", errors)
    return checked, errors


def main():
    crds = json.load(open(sys.argv[1]))
    objects = json.load(open(sys.argv[2]))
    checked, errors = validate(crds, objects)
    for error in errors:
        print("::error::CRD 스키마 위반 " + error)
    if checked == 0:
        print("::error::검사한 사용자 정의 자원이 없다(렌더링·CRD 경로 확인)")
        return 1
    print(f"CRD 스키마 검사: 자원 {checked}개, 위반 {len(errors)}개")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
