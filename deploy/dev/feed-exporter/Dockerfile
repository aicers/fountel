# syntax=docker/dockerfile:1
#
# fountel additive feed-export job (issue #4).
#
# A minimal scheduled worker that drives MISP-native feed generation via
# PyMISP. It reaches MISP only over the REST API (no DB access, no MISP fork)
# and writes the feed-format snapshot to the shared publish volume.

FROM python:3.12-slim

WORKDIR /app
ENV PYTHONUNBUFFERED=1

# PyMISP is pinned to the 2.5 line to match misp-core v2.5.40 (to_feed /
# search_index API). PyYAML reads the pinned export filter.
RUN pip install --no-cache-dir "pymisp>=2.5,<2.6" "PyYAML>=6,<7"

COPY generate_feed.py export-filter.yaml ./

# Runs as an unprivileged user. /feed is created here so that when Docker
# initializes the (empty) named publish volume on first mount, it inherits this
# ownership — letting the non-root exporter write without a chown step.
RUN useradd --system --create-home --uid 10001 exporter \
    && mkdir -p /feed \
    && chown exporter:exporter /feed
USER exporter

ENV FEED_FILTER_PATH=/app/export-filter.yaml \
    FEED_OUTPUT_DIR=/feed \
    FEED_EXPORT_INTERVAL=300

ENTRYPOINT ["python", "/app/generate_feed.py"]
