sudo k3s kubectl get httproute jellyfin -n media \
  -o jsonpath='{range .status.parents[*]}{range .conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{"\n"}{end}{end}'

# B) What hostname is the Gateway LISTENER set to?
sudo k3s kubectl get gateway main -n gateway \
  -o jsonpath='{range .spec.listeners[*]}{.name}{": "}{.hostname}{"\n"}{end}'
