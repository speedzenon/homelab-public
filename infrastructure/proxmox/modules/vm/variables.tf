variable "node_name" {
  type = string
}

variable "vm_id" {
  type = number
}

variable "name" {
  type = string
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "cores" {
  type    = number
  default = 4
}

variable "cpu_type" {
  type    = string
  default = "x86-64-v2-AES" # portowalny baseline -> live migration g-flip<->nas
}

variable "memory" {
  type = number # MiB
}

variable "disk_size" {
  type    = number # GiB, dysk boot na SSD
  default = 40
}

variable "datastore_id" {
  type    = string # SSD tier (rpool/data)
  default = "local-zfs"
}

variable "image_file_id" {
  type = string
}

variable "ip_cidr" {
  type = string # np. x.x.x.x/24 (z network.sops.yaml)
}

variable "gateway" {
  type = string
}

variable "vlan_id" {
  type = number # tag VLAN (k8s = 30)
}

variable "storage_vlan_id" {
  type    = number
  default = null    # null = brak drugiego NIC-a (VM bez storage)
}

variable "storage_mac" {
  type    = string
  default = null    # deterministyczny MAC eth1 (z SOPS); wymagany gdy storage_vlan_id != null
}

variable "on_boot" {
  type    = bool
  default = true
}

variable "extra_disks" {
  type    = list(object({ datastore_id = string, size = number, interface = string }))
  default = []
}
