# 🖥️ Homelab: Multi-Node ARM K3s Cluster with Tailscale & Beszel Monitoring

> A complete self-hosted infrastructure project built on Radxa Rock Pi 4B (2GB) single-board computers. This repository documents the architecture and step-by-step configuration of a secure, private K3s cluster that is monitored and accessible from anywhere.

---

## 📋 Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Hardware Inventory](#hardware-inventory)
- [Quick Start](#quick-start)
- [Detailed Setup Guide](#detailed-setup-guide)
  - [1. Base OS Installation](#1-base-os-installation)
  - [2. Tailscale Mesh Network](#2-tailscale-mesh-network)
  - [3. K3s Cluster Deployment](#3-k3s-cluster-deployment)
  - [4. Beszel Monitoring Stack](#4-beszel-monitoring-stack)
- [Node Labeling Strategy](#node-labeling-strategy)
- [Useful Commands](#useful-commands)
- [Lessons Learned](#lessons-learned)
- [Future Plans](#future-plans)
- [License](#license)

---

## 🎯 Project Overview

This project transforms bare-metal ARM boards into a production-ready Kubernetes cluster using a lightweight, security-first approach. All node-to-node communication and remote access are secured via a Tailscale mesh VPN, while Beszel provides real-time system and container monitoring.

### Key Technologies

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Orchestration** | K3s | Lightweight Kubernetes for ARM |
| **Networking** | Tailscale | Zero-config overlay VPN |
| **Monitoring** | Beszel | Lightweight system & container monitoring |
| **Operating System** | Armbian | Debian-based OS optimized for ARM SBCs |
| **Container Runtime** | containerd | Built into K3s |

---

## 🏗️ Architecture

