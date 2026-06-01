terraform {
  required_version = ">= 1.7.0"
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.9"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }
}
