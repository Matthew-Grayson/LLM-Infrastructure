terraform {
  required_providers {
    oci = { source = "oracle/oci", version = "~> 6.0" }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

resource "oci_core_virtual_network" "vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "llm-free-vcn"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "igw"
  enabled        = true
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.vcn.id
  route_rules {
    network_entity_id = oci_core_internet_gateway.igw.id
    destination       = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_virtual_network.vcn.id
  cidr_block                 = "10.0.1.0/24"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.rt.id
  display_name               = "public-subnet"
  dns_label                  = "pub"
}

resource "oci_core_network_security_group" "nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "llm-nsg"
}

resource "oci_core_network_security_group_security_rule" "ingress_ssh" {
  network_security_group_id = oci_core_network_security_group.nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # tcp
  tcp_options { destination_port_range { min = 22, max = 22 } }
  source      = "0.0.0.0/0"
  source_type = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "ingress_web" {
  network_security_group_id = oci_core_network_security_group.nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # tcp
  tcp_options { destination_port_range { min = 8000, max = 8000 } }
  source      = "0.0.0.0/0"
  source_type = "CIDR_BLOCK"
}

locals {
  cloud_init = <<-CLOUD
  #cloud-config
  package_update: true
  packages:
    - build-essential
    - cmake
    - git
    - wget
    - unzip
  runcmd:
    - cd /opt && git clone https://github.com/ggml-org/llama.cpp && chown -R ubuntu:ubuntu llama.cpp
    - cd /opt/llama.cpp && mkdir -p build && cd build && cmake .. && make -j$(nproc)
    - mkdir -p /opt/models && cd /opt/models
    - wget -q https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf -O tinyllama.q4.gguf
    - 'nohup /opt/llama.cpp/build/bin/llama-server -m /opt/models/tinyllama.q4.gguf -c 2048 -ngl 0 -t $(nproc) --host 0.0.0.0 --port 8000 >/var/log/llama.log 2>&1 &'
  CLOUD
}

resource "oci_core_instance" "a1" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_ocid
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.nsg.id]
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  metadata = {
    user_data = base64encode(local.cloud_init)
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }

  display_name = "llm-free-a1"
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}
