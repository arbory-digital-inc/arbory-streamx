#!/usr/bin/env python3
"""Generates the default-local ingest pipeline .http from its painless sources.

`PUT /_ingest/pipeline/...` replaces the whole pipeline, so every processor has
to be present in the generated file. The existing "ingested" date processor is
lifted verbatim out of the previous migration rather than retyped, so it cannot
drift.

Run from this directory:
    python3 format-ingest-pipelines.py
"""
import json
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
SERVICE_INIT = HERE.parent.parent.parent.parent / "mesh/configs/opensearch/service-init"
PREVIOUS = SERVICE_INIT / "V1.0.0.6.2__update_default_index_default_pipeline.http"
OUTPUT = SERVICE_INIT / "V1.0.0.7.1__update_default_index_default_pipeline.http"
PAINLESS = HERE / "V1.0.0.7.1__parse_searchtags.painless"


def load_previous_processors():
    body = PREVIOUS.read_text().split("\n\n", 1)[1]
    return json.loads(body)["processors"]


def strip_comments(source):
    """Drop full-line // comments; the pipeline body stays readable in git via
    the .painless source, and the embedded copy stays compact."""
    lines = [ln for ln in source.splitlines() if not ln.strip().startswith("//")]
    return "\n".join(lines).strip()


def main():
    processors = load_previous_processors()
    processors.append({
        "script": {
            "description": "Expand payload.facets.searchtags into "
                           "category_level0/1 and category_hierarchy",
            "lang": "painless",
            "ignore_failure": True,
            "source": strip_comments(PAINLESS.read_text()),
        }
    })

    pipeline = {
        "description": "Default ingest pipeline used for default",
        "processors": processors,
    }

    OUTPUT.write_text("PUT /_ingest/pipeline/default-local\n\n"
                      + json.dumps(pipeline, indent=2) + "\n")
    print("wrote %s (%d processors)" % (OUTPUT.name, len(processors)))


if __name__ == "__main__":
    main()
