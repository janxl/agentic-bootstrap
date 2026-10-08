[← How it works](../HOW_IT_WORKS.md) · Appendix

# Windows (WSL2) setup

On Windows, run everything from inside WSL2 (an Ubuntu terminal). This page gets a single-node k3s
cluster and Docker working there. If you already have a cluster (for example Docker Desktop's
Kubernetes), you only need the [Docker](#docker-inside-wsl) section.

## 0. Make sure your distro is WSL 2

Kubernetes needs WSL 2. WSL 1 has no real Linux kernel (no cgroups, no systemd), and `.wslconfig` has no
effect on it. In PowerShell:

```powershell
wsl -l -v
```

The `VERSION` column for your distro (for example `Ubuntu`) must say `2`. If it says `1`, convert it:

```powershell
wsl --set-default-version 2    # new distros use WSL 2
wsl --update                   # current WSL 2 kernel
wsl --set-version Ubuntu 2     # converts the distro; takes a few minutes
```

Back up anything you care about first (`wsl --export Ubuntu C:\ubuntu-backup.tar`). If it complains about
a missing feature, turn on **Virtual Machine Platform** in Windows Features and reboot; virtualisation
must also be enabled in the BIOS. (`docker-desktop-data` showing up in the list is Docker Desktop's own
distro; ignore it.)

## 1. Check whether you need the cgroup change

In WSL, run:

```bash
stat -fc %T /sys/fs/cgroup
```

If it prints `cgroup2fs`, you are already set: skip to [step 3](#3-install-k3s). If it prints `tmpfs`,
do step 2.

## 2. Switch WSL to cgroup v2

Add this to `%UserProfile%\.wslconfig` (create the file if it does not exist):

```ini
[wsl2]
kernelCommandLine = cgroup_no_v1=all
memory=10GB
```

Then run `wsl --shutdown` in PowerShell (this stops every WSL distro and Docker Desktop's backend, so
save your work), reopen WSL, and run the check again.

What the two settings do:

- **`kernelCommandLine = cgroup_no_v1=all`:** cgroups are how Linux limits and tracks the CPU and memory
  that containers use, and Kubernetes depends on them. The WSL2 kernel can start with the older version
  (v1), and current k3s refuses to run on it (`kubelet is configured to not run on a host using cgroup
  v1`). This tells the kernel to use only the newer version (v2). It applies to the whole WSL VM, not
  just one distro.
- **`memory=10GB`:** the most RAM WSL may use. The default is half of your Windows RAM; the local model
  needs about 6 GB free on top of Kubernetes. Lower it if your PC has little memory.

**To undo it:** delete those lines from `.wslconfig` (or delete the file, if nothing else is in it), run
`wsl --shutdown`, and reopen WSL. The check then prints `tmpfs` again. k3s will not start on cgroup v1,
so if you no longer want it, remove it with `sudo /usr/local/bin/k3s-uninstall.sh`.

## 3. Install k3s

```bash
bash scripts/setup-wsl.sh
```

It installs Docker and k3s, and first checks that cgroup v2 and systemd are in place. If it says systemd
is missing, add these two lines to `/etc/wsl.conf` inside WSL, then run `wsl --shutdown` again:

```ini
[boot]
systemd=true
```

## Docker inside WSL

The images are built with Docker, and `make doctor` looks for a `docker` command **inside WSL**. Docker
installed on Windows is not visible from there until you connect it. Pick one:

- **Use Docker Desktop.** Start it, open **Settings → Resources → WSL integration**, switch on your
  Ubuntu distro, click **Apply & restart**, and reopen your WSL terminal. Docker Desktop must be running
  whenever you build.
- **Install Docker in WSL.** `bash scripts/setup-wsl.sh` does this. Or by hand:
  ```bash
  sudo apt-get update && sudo apt-get install -y docker.io
  sudo usermod -aG docker $USER      # then close and reopen the WSL terminal
  ```
  If the daemon is not running afterwards: `sudo service docker start`.

Check with `docker version`.

## Opening the UI from Windows

Use `make open` and browse to `http://localhost:8080`. The ingress that k3s sets up works inside WSL but
is not visible to Windows `localhost`, and a port-forward is.

## Troubleshooting

**`make doctor` says Docker is missing.** See [Docker inside WSL](#docker-inside-wsl).

**I edited `.wslconfig` but nothing changed.** First see what the kernel actually started with:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep cgroup     # should print cgroup_no_v1=all
```

If it prints nothing, WSL did not read the file. The usual reasons:

- **The distro is WSL 1.** See [step 0](#0-make-sure-your-distro-is-wsl-2).
- **Wrong place or name.** It must be `C:\Users\<you>\.wslconfig` on Windows (not inside WSL). Notepad
  often saves it as `.wslconfig.txt`: check with `Get-ChildItem $env:USERPROFILE -Force -Filter ".wslconfig*"`.
- **Wrong encoding.** Windows PowerShell 5.1 writes UTF-16 for `echo ... > file` and `Out-File`, which WSL
  ignores. Write it as plain text instead:
  ```powershell
  Set-Content -Path "$env:USERPROFILE\.wslconfig" -Encoding ascii -Value "[wsl2]","kernelCommandLine = cgroup_no_v1=all","memory=10GB"
  ```
- **No `[wsl2]` header** above the settings, or it is spelled differently.
- **WSL did not really restart.** Run `wsl --shutdown`, check `wsl -l -v` shows every distro as *Stopped*,
  wait about 8 seconds, then reopen. Quit Docker Desktop first, because it can restart the VM.

If the line is there but the check still says v1, run `wsl --update`, then shut down and reopen.

**`cp: cannot stat '/etc/rancher/k3s/k3s.yaml'` (no such file).** k3s has not created its config, so it
is not installed or not running. Check:

```bash
command -v k3s                 # empty: k3s is not installed (rerun the installer and read its output)
ps -p 1 -o comm=               # should print "systemd"; if not, add the [boot] lines above
stat -fc %T /sys/fs/cgroup     # should print "cgroup2fs"; "tmpfs" means do step 2
sudo systemctl status k3s      # still starting? the file appears about 30 seconds after the service starts
sudo journalctl -u k3s -n 30   # why it is failing
```

Running `bash scripts/setup-wsl.sh` avoids most of this, because it checks cgroup v2 and systemd before
installing and tells you which one is wrong.

---

← Previous: [Model choice](model-choice.md)
