"""
Read the parts of a Renovate PR body that the automerge gate and the rollout-revert
workflow act on. Standard library only, so it runs on a bare runner.

Renovate's body is a stable, documented-by-example format:

    This PR contains the following updates:

    | Package | Update | Change |          <- column set varies ("Type", "Pending", ...)
    |---|---|---|
    | [ghcr.io/immich-app/immich-server](https://...) | minor | `v3.2.0` → `v3.3.1` |
    ...
    ### Release Notes
    ...
    ### Configuration                       <- Renovate's own footer starts here
    🚦 **Automerge**: Enabled.

Columns are located by header name, never by position.
"""
import re

_LINK = re.compile(r"^\[([^\]]+)\]\(")
_CODE = re.compile(r"`([^`]+)`")


def _cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def parse_deps(body):
    """Return [{dep, update, from, to}] from the first updates table in the body."""
    lines = (body or "").splitlines()
    deps = []
    for i, line in enumerate(lines):
        if not line.lstrip().startswith("|"):
            continue
        header = [c.lower() for c in _cells(line)]
        if "package" not in header or "change" not in header:
            continue
        col = {name: header.index(name) for name in header}
        for row in lines[i + 2:]:  # skip the |---| separator
            if not row.lstrip().startswith("|"):
                break
            cells = _cells(row)
            if len(cells) < len(header):
                continue
            pkg = cells[col["package"]]
            m = _LINK.match(pkg)
            dep = (m.group(1) if m else pkg).strip("`").strip()
            versions = _CODE.findall(cells[col["change"]])
            deps.append({
                "dep": dep,
                "update": cells[col["update"]].lower() if "update" in col else "",
                "from": versions[0] if len(versions) > 0 else "",
                "to": versions[-1] if len(versions) > 1 else "",
            })
        break
    return deps


def strip_boilerplate(body):
    """The body minus HTML comments and Renovate's Configuration footer.

    Keeps the update table and the release notes — the parts written about THIS
    update — and drops the parts Renovate writes on every PR, so a keyword scan
    is not tripped by Renovate's own wording.
    """
    text = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    cut = re.search(r"^#+\s*Configuration\s*$", text, flags=re.M)
    return text[: cut.start()] if cut else text


def automerge_enabled(body):
    """Renovate's own verdict, from the footer: `🚦 **Automerge**: Enabled.`"""
    return re.search(r"\*\*Automerge\*\*:\s*Enabled", body or "") is not None
