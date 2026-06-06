variable "node_name"     { type = string }
variable "vm_id"         { type = number }
variable "name"          { type = string }
variable "tags"          { type = list(string), default = [] }
variable "cores"         { type = number, default = 4 }
variable "cpu_type"      { type = string, default = "x86-64-v2-AES" } # portowalny baseline -> live migration g-flip<->nas
variable "memory"        { type = number }                           # MiB
variable "disk_size"     { type = number, default = 40 }             # GiB, dysk boot na SSD
variable "datastore_id"  { type = string, default = "local-zfs" }    # SSD tier (rpool/data)
variable "image_file_id" { type = string }                           # z proxmox_virtual_environment_download_file
variable "ip_cidr"       { type = string }                           # np. x.x.x.x/24 (z network.sops.yaml)
variable "gateway"       { type = string }
variable "vlan_id"       { type = number }                           # tag VLAN (k8s = 30)
variable "on_boot"       { type = bool, default = true }
variable "extra_disks" {                                             # tier pojemnosciowy (HDD) - puste dla node'ow k8s
  type    = list(object({ datastore_id = string, size = number, interface = string }))
  default = []
}
