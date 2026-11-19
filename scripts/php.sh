# Sourced by keygen.sh and promote.sh: php_run <php args...> runs PHP from PATH, or from a pinned image when php is not
# installed. Secrets reach it on stdin only; `--log-driver none` keeps the container's output out of Docker's logs.
php_run() {
  if command -v php >/dev/null; then php "$@"; return; fi
  MSYS_NO_PATHCONV=1 docker run -i --rm --log-driver none \
    php:8.3-cli-alpine@sha256:e7699f91d3b46283a49bde02379266dd98d87844e08aed1ff7ea6a7d1f031268 php "$@" # php:8.3-cli-alpine
}
