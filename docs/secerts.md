# Argo CD + KSOPS + SOPS + age

This directory contains the Argo CD installation and configuration required to manage SOPS-encrypted Kubernetes Secrets using KSOPS.

The goal of this setup is to allow encrypted secrets to safely remain in Git while Argo CD decrypts them during manifest generation.

The most important security principle is:

> **Git stores the encrypted Secret. The Argo CD repo-server holds the age private key and performs decryption during manifest generation.**

The plaintext secret does not need to be stored in Git.

---

## Table of Contents

- [Overview](#overview)
- [Why This Architecture Exists](#why-this-architecture-exists)
- [High-Level Architecture](#high-level-architecture)
- [The Mental Model](#the-mental-model)
- [Components](#components)
  - [Git](#git)
  - [Kubernetes](#kubernetes)
  - [Argo CD](#argo-cd)
  - [Argo CD Repo-Server](#argo-cd-repo-server)
  - [Kustomize](#kustomize)
  - [Kustomize Generators](#kustomize-generators)
  - [KSOPS](#ksops)
  - [SOPS](#sops)
  - [age](#age)
  - [.sops.yaml](#sopsyaml)
- [How the Components Fit Together](#how-the-components-fit-together)
- [Directory Structure](#directory-structure)
- [Argo CD Installation](#argo-cd-installation)
- [Repo-Server KSOPS Configuration](#repo-server-ksops-configuration)
- [KSOPS Installation](#ksops-installation)
- [Kustomize Plugin Directory](#kustomize-plugin-directory)
- [Argo CD Kustomize Options](#argo-cd-kustomize-options)
- [SOPS Encryption](#sops-encryption)
- [age Encryption](#age-encryption)
- [.sops.yaml](#sopsyaml-1)
- [Kubernetes age Private Key](#kubernetes-age-private-key)
- [Application Secret Structure](#application-secret-structure)
- [The Two Secret Files](#the-two-secret-files)
- [Application Kustomization](#application-kustomization)
- [Full End-to-End Flow](#full-end-to-end-flow)
- [What Happens During Argo CD Manifest Generation](#what-happens-during-argo-cd-manifest-generation)
- [What Happens During Argo CD Sync](#what-happens-during-argo-cd-sync)
- [Creating a New Encrypted Secret](#creating-a-new-encrypted-secret)
- [Testing Locally](#testing-locally)
- [Testing Inside Argo CD](#testing-inside-argo-cd)
- [Testing the Full Argo CD Flow](#testing-the-full-argo-cd-flow)
- [Troubleshooting](#troubleshooting)
- [Debugging by Layer](#debugging-by-layer)
- [Security Model](#security-model)
- [Trust Boundaries](#trust-boundaries)
- [What This Setup Protects](#what-this-setup-protects)
- [What This Setup Does Not Protect](#what-this-setup-does-not-protect)
- [Bootstrap Problem](#bootstrap-problem)
- [Key Rotation](#key-rotation)
- [What Happens if the Private Key Is Compromised](#what-happens-if-the-private-key-is-compromised)
- [Operational Checklist](#operational-checklist)
- [Git Checklist](#git-checklist)
- [Security Rules](#security-rules)
- [Learning Exercises](#learning-exercises)
- [Commands Cheat Sheet](#commands-cheat-sheet)
- [Glossary](#glossary)
- [Important Concepts to Learn Next](#important-concepts-to-learn-next)
- [Quick Recipe](#quick-recipe)
- [Final Mental Model](#final-mental-model)

---

## Overview

This setup combines:

- Git
- Argo CD
- Kustomize
- KSOPS
- SOPS
- age
- Kubernetes Secrets

to implement GitOps-based secret management.

The architecture looks like this:

```text
                         Git
                          |
                          | encrypted Secret
                          v
                    *.enc.yaml
                          |
                          v
                   Argo CD repo-server
                          |
                          v
                      Kustomize
                          |
                          v
                        KSOPS
                          |
                          v
                         SOPS
                          |
                          | age private key
                          v
                    Decrypted Secret
                          |
                          v
                     Argo CD sync
                          |
                          v
                      Kubernetes
```

**The key idea is:**

- Git contains encrypted data
- Argo CD repo-server performs decryption
- Kubernetes receives the resulting Secret

---

## Why This Architecture Exists

Kubernetes Secrets contain sensitive information such as:

- Passwords
- API keys
- Tokens
- Database credentials
- TLS private keys
- Application credentials

A simple Kubernetes Secret might look like:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secret
  namespace: apps
type: Opaque
stringData:
  PASSWORD: "super-secret-password"
```

If this file is committed directly to Git, the plaintext secret becomes part of the Git repository history.

Even deleting the file later does not necessarily remove the secret from Git history.

**SOPS solves this problem** by encrypting the sensitive values before they are committed.

Instead of:

```yaml
stringData:
  PASSWORD: "super-secret-password"
```

Git contains something like:

```yaml
stringData:
  PASSWORD: ENC[AES256_GCM,...]
```

The secret is therefore encrypted before it enters Git.

---

## High-Level Architecture

The complete architecture is:

```text
┌──────────────────────────────────────────────────────────────┐
│                         Git Repository                       │
│                                                              │
│  kustomization.yaml                                          │
│  deployment.yaml                                             │
│  service.yaml                                                │
│  degoog-secret.sops.yaml                                     │
│  degoog-secret.enc.yaml                                      │
│  .sops.yaml                                                  │
│                                                              │
│              encrypted secret values only                    │
└──────────────────────────────┬───────────────────────────────┘
                               │
                               │ Git
                               ▼
┌──────────────────────────────────────────────────────────────┐
│                    Argo CD repo-server                       │
│                                                              │
│  Kustomize                                                   │
│      │                                                       │
│      ▼                                                       │
│  KSOPS                                                       │
│      │                                                       │
│      ▼                                                       │
│  SOPS                                                        │
│      │                                                       │
│      ▼                                                       │
│  age private key                                             │
│                                                              │
│  /etc/sops-age/keys.txt                                      │
└──────────────────────────────┬───────────────────────────────┘
                               │
                               │ rendered manifests
                               ▼
┌──────────────────────────────────────────────────────────────┐
│                         Argo CD                              │
│                                                              │
│                 Desired state comparison                     │
└──────────────────────────────┬───────────────────────────────┘
                               │
                               │ Kubernetes API
                               ▼
┌──────────────────────────────────────────────────────────────┐
│                       Kubernetes                             │
│                                                              │
│  Secret                                                      │
│  Deployment                                                  │
│  Service                                                     │
│  Ingress                                                     │
└──────────────────────────────────────────────────────────────┘
```

---

## The Mental Model

There are two important worlds in this architecture.

### Git World

Git contains the desired configuration.

```text
Git
 |
 +-- Deployment
 +-- Service
 +-- Ingress
 +-- Kustomization
 +-- KSOPS generator
 +-- encrypted Secret
```

**Git should NOT contain:**

- Plaintext password
- Plaintext API key
- age private key

### Cluster World

Kubernetes contains the actual running state.

```text
Kubernetes
 |
 +-- Deployments
 +-- Services
 +-- Ingresses
 +-- Secrets
 +-- ConfigMaps
```

### Argo CD Connects These Two Worlds

```text
                 Git
                  |
                  | desired state
                  v
               Argo CD
                  |
                  | reconciliation
                  v
              Kubernetes
                  |
                  | actual state
                  └───────────────┐
                                  |
                                  └── compared with Git
```

---

## Components

Each technology has a different responsibility.

The easiest way to understand the system is to avoid thinking of "Argo CD + KSOPS + SOPS + age" as one thing. They are separate components.

### Git

Git is the source of truth for the desired configuration.

**Git stores:**

- \`deployment.yaml\`
- \`service.yaml\`
- \`ingress.yaml\`
- \`kustomization.yaml\`
- \`*.sops.yaml\`
- \`*.enc.yaml\`
- \`.sops.yaml\`

**Git should NOT store:**

- \`plaintext-secret.yaml\`
- \`*.key\`
- \`*.age\`
- age private key
- Plaintext password
- Plaintext API token

**The important distinction is:**

- Git = desired state
- Kubernetes = actual state
- Argo CD = reconciler between the two

### Kubernetes

Kubernetes is the target system.

Argo CD ultimately sends rendered Kubernetes manifests to the Kubernetes API.

The resulting resources can include:

- Deployment
- Service
- Ingress
- ConfigMap
- Secret
- PersistentVolumeClaim

Kubernetes Secrets are still sensitive resources.

- SOPS protects the secret while it is stored in Git
- Kubernetes security controls protect the secret after it enters the cluster

These are two different security problems:

```text
Git security + Kubernetes security
```

### Argo CD

Argo CD is the GitOps controller.

Its basic job is:

```text
Git desired state
        |
        v
Generate manifests
        |
        v
Compare with Kubernetes
        |
        v
Apply changes
```

Argo CD continuously asks:

- What does Git say the cluster should look like?
- What does the Kubernetes cluster actually look like?

If they differ, the application may become **OutOfSync**.

If they match: **Synced**.

**Important:** Argo CD is NOT the encryption mechanism.

- SOPS handles encryption/decryption
- KSOPS integrates SOPS with Kustomize
- Argo CD orchestrates the overall GitOps process

### Argo CD Repo-Server

The repo-server is extremely important in this architecture.

The repo-server is responsible for repository access and manifest generation.

Conceptually:

```text
Git
 |
 v
repo-server
 |
 +-- Kustomize
 |
 +-- KSOPS
 |
 +-- SOPS
 |
 +-- age private key
 |
 v
Rendered manifests
```

The repo-server is therefore where the encrypted Git representation becomes a decrypted Kubernetes manifest.

**This also makes the repo-server a highly trusted component.** It has access to the age private key.

### Kustomize

Kustomize is responsible for building Kubernetes manifests.

A Kustomization might contain:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

Kustomize takes these pieces and builds a final set of Kubernetes manifests.

Conceptually:

```text
kustomization.yaml
       |
       +-- deployment.yaml
       +-- service.yaml
       +-- ingress.yaml
       |
       v
Kustomize build
       |
       v
Rendered manifests
```

Kustomize itself is not the secret encryption mechanism.

### Kustomize Generators

Kustomize supports generators.

Generators produce resources during the Kustomize build process.

Your application contains:

```yaml
generators:
  - degoog-secret.sops.yaml
```

This tells Kustomize that it needs to execute the generator.

In your setup, that generator is KSOPS.

### KSOPS

KSOPS is the bridge between Kustomize and SOPS.

The relationship is:

```text
Kustomize
    |
    | generator
    v
  KSOPS
    |
    | invokes
    v
  SOPS
    |
    | uses
    v
   age
```

KSOPS does not replace SOPS. KSOPS integrates SOPS into the Kustomize build process.

Without KSOPS:

```text
Kustomize ----X---- SOPS
```

With KSOPS:

```text
Kustomize
    |
    v
  KSOPS
    |
    v
  SOPS
    |
    v
   age
```

### SOPS

SOPS is responsible for encryption and decryption of structured data.

For example:

```yaml
stringData:
  PASSWORD: "super-secret"
```

can become:

```yaml
stringData:
  PASSWORD: ENC[AES256_GCM,...]
```

SOPS also stores metadata describing how the file is encrypted.

Conceptually:

```text
SOPS
 |
 +-- encrypt values
 |
 +-- decrypt values
 |
 +-- maintain integrity metadata
 |
 +-- use encryption key mechanism
```

SOPS is not the encryption key itself. In this architecture, SOPS uses age.

### age

age is the encryption mechanism used by SOPS.

It uses public/private key cryptography.

Conceptually:

```text
                    age key pair

              ┌─────────────────────┐
              │                     │
              ▼                     ▼
        Public key             Private key
        recipient              secret identity
              │                     │
              │                     │
              ▼                     ▼
             Git                repo-server
              │                     │
              │                     │
              ▼                     ▼
           encrypt              decrypt
```

The public key can safely be stored in Git.

The private key must remain secret.

Example public recipient:

```
age1...
```

Example private identity:

```
AGE-SECRET-KEY-1...
```

The public recipient is safe to commit. The private identity must never be committed.

### .sops.yaml

\`.sops.yaml\` is the SOPS configuration/policy file.

Example:

```yaml
creation_rules:
  - path_regex: .*\\.enc\\.yaml$
    encrypted_regex: "^(data|stringData)$"
    age: "age1..."
```

This answers three questions:

```text
Which files should this rule apply to?
            |
            v
Which fields should be encrypted?
            |
            v
Which age recipient should be used?
```

#### path_regex

Example:

```yaml
path_regex: .*\\.enc\\.yaml$
```

**Matches:**

- \`myapp-secret.enc.yaml\`
- \`database.enc.yaml\`
- \`tls.enc.yaml\`

**Does not match:**

- \`myapp-secret.sops.yaml\`
- \`deployment.yaml\`
- \`service.yaml\`

#### encrypted_regex

Example:

```yaml
encrypted_regex: "^(data|stringData)$"
```

This tells SOPS to encrypt:

```yaml
data:
  PASSWORD: ...

stringData:
  PASSWORD: ...
```

but not necessarily:

```yaml
metadata:
  name: myapp-secret
  namespace: apps
```

This allows Kubernetes metadata to remain readable.

#### age

Example:

```yaml
age: "age1..."
```

This is the public age recipient. The corresponding private age key is required for decryption.

---

## How the Components Fit Together

The complete dependency chain is:

```text
Git
 |
 v
Argo CD
 |
 v
repo-server
 |
 v
Kustomize
 |
 v
KSOPS
 |
 v
SOPS
 |
 v
age private key
 |
 v
decrypted Secret
 |
 v
Argo CD
 |
 v
Kubernetes
```

Each component has one primary responsibility:

| Component | Responsibility |
|-----------|----------------|
| Git | Stores desired configuration |
| Argo CD | Reconciles Git and Kubernetes |
| repo-server | Generates manifests |
| Kustomize | Builds manifests |
| KSOPS | Connects Kustomize to SOPS |
| SOPS | Encrypts/decrypts secret values |
| age | Provides public/private key encryption |
| Kubernetes | Runs workloads and stores Secrets |

---

## Directory Structure

A typical repository may look like:

```text
.
├── .sops.yaml
│
├── gitops/
│   │
│   ├── argocd/
│   │   ├── kustomization.yaml
│   │   ├── argocd-install.yaml
│   │   ├── repo-server-ksops-patch.yaml
│   │   ├── argocd-cm.yaml
│   │   ├── config.yaml
│   │   └── ingress.yaml
│   │
│   └── myapp/
│       ├── kustomization.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── pvc.yaml
│       ├── myapp-secret.sops.yaml
│       └── myapp-secret.enc.yaml
│
└── README.md
```

---

## Argo CD Installation

### argocd-install.yaml

This contains the Argo CD installation manifests.

It provides components such as:

- argocd-server
- argocd-repo-server
- argocd-application-controller
- Redis
- ApplicationSet controller
- Dex
- RBAC
- Services
- CRDs

### kustomization.yaml

This is the Kustomize entry point for the Argo CD installation.

Example:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - argocd-install.yaml
  - config.yaml
  - ingress.yaml
  - argocd-cm.yaml

patches:
  - path: repo-server-ksops-patch.yaml
```

Conceptually:

```text
argocd-install.yaml
        |
        +-- base Argo CD
        |
        v
Kustomize
        |
        +-- repo-server patch
        |
        v
Final Argo CD manifests
```

---

## Repo-Server KSOPS Configuration

\`repo-server-ksops-patch.yaml\` modifies the Argo CD repo-server.

It performs several important tasks:

- Creates a shared volume for custom binaries
- Creates a plugin directory
- Installs KSOPS
- Installs Kustomize
- Provides the age private key
- Configures SOPS to find the private key
- Configures Kustomize plugin discovery

Important volumes include:

```yaml
- name: custom-tools
  emptyDir: {}
- name: kustomize-plugins
  emptyDir: {}
- name: sops-age
  secret:
    secretName: sops-age
```

---

## KSOPS Installation

The repo-server has an init container similar to:

```yaml
- name: install-ksops
  image: viaductoss/ksops:v4.5.1
  command:
    - /usr/local/bin/ksops
    - install
    - --with-kustomize
    - /custom-tools
```

The init container runs before the main repo-server container.

Conceptually:

```text
Pod starts
   |
   v
install-ksops init container
   |
   +-- install ksops
   +-- install kustomize
   |
   v
/custom-tools
   |
   v
repo-server starts
```

The tools are shared using the custom-tools volume.

The repo-server then has access to:

```text
/custom-tools/ksops
/custom-tools/kustomize
```

which can be mounted as:

```text
/usr/local/bin/ksops
/usr/local/bin/kustomize
```

---

## Kustomize Plugin Directory

Kustomize needs to know where its plugins are located.

Your setup uses:

```text
/home/argocd/.config/kustomize/plugin
```

The deployment therefore needs:

```yaml
- name: kustomize-plugins
  emptyDir: {}
```

mounted at:

```text
/home/argocd/.config/kustomize/plugin
```

and:

```yaml
- name: KUSTOMIZE_PLUGIN_HOME
  value: /home/argocd/.config/kustomize/plugin
```

The important relationship is:

```text
KUSTOMIZE_PLUGIN_HOME
          |
          v
/home/argocd/.config/kustomize/plugin
          |
          v
Kustomize plugin discovery
          |
          v
KSOPS
```

---

## Argo CD Kustomize Options

\`argocd-cm.yaml\` contains:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd

data:
  kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"
```

These options tell Argo CD's Kustomize invocation to allow the required plugin functionality.

Without the appropriate plugin options, Argo CD may not execute KSOPS.

**Verify:**

```bash
kubectl kustomize gitops/argocd/ | grep -A2 -B2 'kustomize.buildOptions'
```

Expected:

```text
kustomize.buildOptions: --enable-alpha-plugins --enable-exec
```

---

## SOPS Encryption

SOPS encrypts the secret values.

**Example plaintext:**

```yaml
apiVersion: v1
kind: Secret

metadata:
  name: example
  namespace: apps

type: Opaque

stringData:
  PASSWORD: "super-secret"
```

**After encryption:**

```yaml
apiVersion: v1
kind: Secret

metadata:
  name: example
  namespace: apps

type: Opaque

stringData:
  PASSWORD: ENC[AES256_GCM,...]

sops:
  age:
    ...
```

The secret value is now encrypted.

SOPS also stores integrity information.

If encrypted data is modified incorrectly, SOPS may report:

```text
MAC mismatch
```

or:

```text
Failed to verify data integrity
```

This is intentional.

---

## age Encryption

The age public key is stored in \`.sops.yaml\`.

Example:

```yaml
age: "age1..."
```

The private key is stored outside Git.

Conceptually:

```text
              age

       Public key
           |
           | encrypt
           v
     encrypted secret
           |
           | decrypt
           v
       Private key
```

**Public key:** SAFE TO COMMIT

**Private key:** NEVER COMMIT

---

## .sops.yaml

The repository root contains \`.sops.yaml\`.

Example:

```yaml
creation_rules:
  - path_regex: .*\\.enc\\.yaml$
    encrypted_regex: "^(data|stringData)$"
    age: "age1rvqfv9w738ucl3w8fctvp30p738s72t682dg5vwws5laxm3ek94qlczs34"
```

This means:

```text
*.enc.yaml
      |
      v
SOPS encryption rule
      |
      +-- encrypt data
      +-- encrypt stringData
      |
      +-- use age recipient
```

The public age recipient can safely be committed.

---

## Kubernetes age Private Key

Argo CD needs the corresponding age private key to decrypt secrets.

The private key is stored in Kubernetes:

```text
Secret: argocd/sops-age
```

The repo-server mounts it as:

```text
/etc/sops-age/keys.txt
```

SOPS is configured with:

```text
SOPS_AGE_KEY_FILE=/etc/sops-age/keys.txt
```

The complete relationship is:

```text
Kubernetes Secret
       |
       v
sops-age
       |
       | mounted into Pod
       v
/etc/sops-age/keys.txt
       |
       v
SOPS_AGE_KEY_FILE
       |
       v
SOPS
       |
       v
age private key
```

**Verify the environment variable:**

```bash
kubectl -n argocd exec deployment/argocd-repo-server \
  -c argocd-repo-server -- \
  sh -c 'echo "$SOPS_AGE_KEY_FILE"'
```

Expected:

```text
/etc/sops-age/keys.txt
```

> **⚠️ Do not print the contents of the key.**

---

## Application Secret Structure

A typical application looks like:

```text
gitops/myapp/

├── kustomization.yaml
├── deployment.yaml
├── service.yaml
├── ingress.yaml
├── pvc.yaml
├── myapp-secret.sops.yaml
└── myapp-secret.enc.yaml
```

---

## The Two Secret Files

This distinction is extremely important.

There are two different files:

- \`myapp-secret.sops.yaml\`
- \`myapp-secret.enc.yaml\`

They have completely different jobs.

### myapp-secret.sops.yaml

This is the KSOPS generator. It is NOT the encrypted Secret.

Example:

```yaml
apiVersion: viaduct.ai/v1
kind: ksops

metadata:
  name: myapp-secret
  namespace: apps

  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops

files:
  - ./myapp-secret.enc.yaml
```

Conceptually:

```text
myapp-secret.sops.yaml
        |
        | tells KSOPS what to process
        v
myapp-secret.enc.yaml
```

### myapp-secret.enc.yaml

This is the actual encrypted Kubernetes Secret.

Example:

```yaml
apiVersion: v1
kind: Secret

metadata:
  name: myapp-secret
  namespace: apps

type: Opaque

stringData:
  PASSWORD: ENC[AES256_GCM,...]

sops:
  age:
    ...
```

This is the file that can safely be committed to Git.

---

## Application Kustomization

The application \`kustomization.yaml\` should include the generator.

Example:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - pvc.yaml

generators:
  - myapp-secret.sops.yaml
```

**Do not put the encrypted Secret directly under \`resources:\`.**

Instead use:

```yaml
generators:
  - myapp-secret.sops.yaml
```

The relationship is:

```text
kustomization.yaml
        |
        v
myapp-secret.sops.yaml
        |
        v
myapp-secret.enc.yaml
        |
        v
KSOPS
        |
        v
SOPS
        |
        v
Kubernetes Secret
```

---

## Full End-to-End Flow

This is the most important section of this README.

The complete flow is:

```text
Developer
    |
    | creates plaintext Secret
    v
SOPS
    |
    | encrypt using age public key
    v
*.enc.yaml
    |
    | git commit
    v
Git repository
    |
    | Argo CD detects change
    v
Argo CD
    |
    v
repo-server
    |
    v
Kustomize
    |
    v
KSOPS
    |
    v
SOPS
    |
    | reads SOPS_AGE_KEY_FILE
    v
age private key
    |
    v
decrypted Kubernetes Secret
    |
    v
rendered manifests
    |
    v
Argo CD
    |
    | Kubernetes API
    v
Kubernetes
```

---

## What Happens During Argo CD Manifest Generation

Let's walk through the process in detail.

### Step 1: Argo CD detects Git state

Argo CD knows the application points to:

- Git repository
- Revision
- Path

It detects that it needs to generate manifests.

### Step 2: repo-server gets the repository

The repo-server obtains the repository contents.

It now has something conceptually like:

```text
kustomization.yaml
deployment.yaml
service.yaml
myapp-secret.sops.yaml
myapp-secret.enc.yaml
```

### Step 3: Kustomize starts

Argo CD invokes Kustomize with the configured options.

Conceptually:

```bash
kustomize build \
  --enable-alpha-plugins \
  --enable-exec \
  gitops/myapp
```

### Step 4: Kustomize sees the generator

Kustomize reads:

```yaml
generators:
  - myapp-secret.sops.yaml
```

It sees \`kind: ksops\` and invokes KSOPS.

### Step 5: KSOPS loads the encrypted file

KSOPS loads:

```text
myapp-secret.enc.yaml
```

The secret value is still encrypted.

Example:

```yaml
stringData:
  PASSWORD: ENC[AES256_GCM,...]
```

### Step 6: KSOPS invokes SOPS

KSOPS calls SOPS to process the encrypted file.

SOPS needs the age private key.

### Step 7: SOPS finds the age private key

The repo-server has:

```text
SOPS_AGE_KEY_FILE=/etc/sops-age/keys.txt
```

The file is backed by the Kubernetes Secret \`argocd/sops-age\`.

SOPS reads the identity