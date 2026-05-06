# Shared bats helpers for claudev test suite.

# _canonpath <dir>: print absolute, OS-native path to <dir>, resolving '..'.
# On MSYS/Cygwin Git Bash, emits Windows-form (C:/...) so node.exe can resolve it.
# On macOS/Linux, emits a plain POSIX absolute path. Required because node.exe
# cannot resolve unconverted `/c/Users/...` MSYS paths with `..` components.
_canonpath() {
  if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]] || command -v cygpath >/dev/null 2>&1; then
    (cd "$1" && pwd -W)
  else
    (cd "$1" && pwd)
  fi
}
