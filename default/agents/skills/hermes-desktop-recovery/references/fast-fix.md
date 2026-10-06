# Fast fix (copy/paste)

```bash
# 1) Match desktop shell to agent
hermes desktop --build-only --force-build

# 2) Ensure Omarchy user launcher wins
type -a hermes-desktop   # expect ~/.config/omarchy/bin/hermes-desktop first

# 3) Software GPU on weak NVIDIA
grep DISABLE_GPU ~/.config/omarchy/bin/hermes-desktop || \
  echo 'export HERMES_DESKTOP_DISABLE_GPU=1' >> ~/.config/omarchy/bin/hermes-desktop

# 4) Launch + verify
hermes-desktop &
sleep 8
rg 'backend is ready|IGNORE_EXISTING|predates|FATAL' ~/.hermes/logs/desktop.log | tail -15
```

Not a HackerOne bounty: upstream Electron/Hermes crashes Omarchy merely ships (see local TRIAGE).
