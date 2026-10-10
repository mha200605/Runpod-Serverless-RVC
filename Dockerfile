# syntax=docker/dockerfile:1
# RVC v2 voice-conversion worker for RunPod Serverless (file/API based, not real-time).
#
# Pins
#   Applio     : commit 29b4a00e4be209f9aac51cd9ccffcc632dfb2973 (source read in full: rvc/infer/infer.py, core.py)
#   Python     : 3.10 (Applio's core.py imports distutils, removed in 3.12)
#   Applio deps: whatever that commit's requirements.txt pins (installed verbatim)
#   runpod SDK : requirements-worker.txt
# The full resolved set is printed at the end of the build ("pip freeze"). Commit it as
# requirements.lock.txt after the first successful build to freeze everything.
ARG PYTHON_VERSION=3.10
FROM python:${PYTHON_VERSION}-slim-bookworm

ARG APPLIO_REPO=https://github.com/IAHispano/Applio.git
ARG APPLIO_COMMIT=29b4a00e4be209f9aac51cd9ccffcc632dfb2973
ARG INSTALL_S3=0

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APPLIO_DIR=/opt/applio

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ffmpeg libsndfile1 build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 1) Applio at the exact pinned commit (fails the build if the fetched commit differs).
WORKDIR /opt/applio
RUN git init -q . \
 && git remote add origin "${APPLIO_REPO}" \
 && git fetch -q --depth 1 origin "${APPLIO_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "${APPLIO_COMMIT}" \
 && git rev-parse HEAD > PINNED_COMMIT \
 && rm -rf .git

# 2) Applio's own pinned dependencies, then the worker's.
RUN pip install --upgrade pip && pip install -r requirements.txt
COPY requirements-worker.txt requirements-s3.txt /app/
RUN pip install -r /app/requirements-worker.txt \
 && if [ "${INSTALL_S3}" = "1" ]; then pip install -r /app/requirements-s3.txt; fi

# 3) Base models (RMVPE pitch extractor + ContentVec embedder) baked into the image so cold
#    starts never wait on a download. Voice models (.pth/.index) are NOT baked in.
COPY scripts/ /app/scripts/
RUN python /app/scripts/build_prereqs.py
RUN python /app/scripts/smoke_import.py

# 4) Record exactly what was installed (copy this from the build log into requirements.lock.txt).
RUN echo "===== pip freeze =====" && pip freeze && echo "===== end pip freeze ====="

# 5) Worker code last so code edits do not invalidate the heavy layers above.
COPY src/ /app/
WORKDIR /opt/applio
CMD ["python", "-u", "/app/handler.py"]
