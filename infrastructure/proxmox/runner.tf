# Runner Forgejo Actions: mala VM Debian 13, zwykle WYLACZONA. Start: 'just runner-up',
# VM sama sie wylacza po 30 min bez jobow (Ansible: infrastructure/ansible/runner.yml).
# VM, a nie LXC: joby maja gniazdo podmana (buduja obrazy), wiec granica miedzy jobem
# a hostem musi byc hypervisorem, nie wspolnym jadrem - docs/adr/0002-runner-w-vm-na-zadanie.md.
# Dane z SOPS: vms.runner (vmid, host, vlan, ip) i admin_ssh_keys.
locals {
  runner      = local.net.vms.runner
  runner_vlan = local.net.vlans[local.runner.vlan]
  runner_node = local.pve_node[local.runner.host]
}

# Obraz cloud Debiana (cloud-init). Tylko do UTWORZENIA VM - pozniejsze wersje
# obrazu nie maja znaczenia (system aktualizuje Ansible i unattended-upgrades).
# .img: storage typu iso przyjmuje tylko .iso/.img; format qcow2 PVE rozpoznaje sam.
resource "proxmox_download_file" "debian13" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = local.runner_node
  url          = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name    = "debian-13-genericcloud-amd64.img"
  overwrite    = false
}

module "runner" {
  source = "./modules/vm"

  node_name     = local.runner_node
  vm_id         = local.runner.vmid
  name          = "runner"
  tags          = ["tofu", "ansible", "ci"]
  cores         = 2
  memory        = 4096
  disk_size     = 32
  datastore_id  = "local-zfs"
  image_file_id = proxmox_download_file.debian13.id
  ip_cidr       = "${local.runner.ip}/${split("/", local.runner_vlan.cidr)[1]}"
  gateway       = local.runner_vlan.gateway
  vlan_id       = local.runner_vlan.id
  dns_servers   = [local.runner_vlan.gateway]
  # Wylaczona po starcie hosta; wlaczana na zadanie
  on_boot  = false
  firewall = true
  # Agenta QEMU instaluje dopiero Ansible, a VM zwykle stoi - tofu nie czeka na adres
  agent_wait_for_ip = false
  user_account = {
    username = "ansible"
    keys     = local.net.admin_ssh_keys
  }
}

# Firewall VM: grupa runner-srv (firewall.tf), wejscie DROP. ipfilter: VM moze
# wysylac tylko z adresu z SOPS (dla VM PVE nie zna adresow sam - ipset jawnie).
resource "proxmox_virtual_environment_firewall_ipset" "runner_ipfilter" {
  node_name = local.runner_node
  vm_id     = module.runner.vm_id
  name      = "ipfilter-net0"
  comment   = "Dozwolony adres zrodlowy VM runner"
  cidr {
    name = local.runner.ip
  }
}

resource "proxmox_virtual_environment_firewall_rules" "runner" {
  node_name = local.runner_node
  vm_id     = module.runner.vm_id
  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.runner_srv.name
  }

  lifecycle {
    precondition {
      condition     = local.runner.vmid == floor(local.runner_vlan.id / 10) * 100 + tonumber(split(".", local.runner.ip)[3])
      error_message = "vms.runner: VMID ${local.runner.vmid} nie wynika z VLAN-u ${local.runner_vlan.id} i adresu (docs/runbooks/local-addressing.md)."
    }
  }
}

resource "proxmox_virtual_environment_firewall_options" "runner" {
  node_name     = local.runner_node
  vm_id         = module.runner.vm_id
  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  ipfilter      = true
  macfilter     = true
  dhcp          = false # adres statyczny z cloud-init
  ndp           = false # IPv6 nieuzywane
  radv          = false
  depends_on    = [proxmox_virtual_environment_firewall_rules.runner, proxmox_virtual_environment_firewall_ipset.runner_ipfilter]
}
