variable "talos_version" {
  type    = string
  default = "1.12.6"
}

variable "talos_schematic_id" {
  type        = string
  description = "Image Factory schematic ID (qemu-guest-agent + iscsi-tools + util-linux-tools)."
  default     = "53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83" # klucz do id image
}
