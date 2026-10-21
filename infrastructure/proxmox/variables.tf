# Wersje Talosa (obraz boot z Image Factory) - jedno zrodlo z justfile:
# talos/versions.yaml (version, schematic, kubernetes).
locals {
  talos = yamldecode(file("${path.module}/../../talos/versions.yaml"))
}
