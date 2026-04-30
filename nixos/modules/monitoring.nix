# monitoring.nix — Azure Monitor integration and node_exporter
#
# Enables Prometheus node_exporter for scraping by Azure Monitor managed
# Prometheus, and configures the Azure Monitor agent (AMA) if available.

{ config, pkgs, ... }:

{
  # ── Prometheus node_exporter ─────────────────────────────────────────
  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [
      "systemd"
      "cpu"
      "diskstats"
      "filesystem"
      "loadavg"
      "meminfo"
      "netdev"
      "netstat"
      "stat"
      "time"
      "uname"
    ];
    # node_exporter listens on localhost only; Azure Monitor scrapes via the
    # managed Prometheus endpoint or a local scrape config.
    listenAddress = "127.0.0.1";
    port = 9100;
  };

  # ── Firewall: allow Prometheus scrape from local AMA agent ───────────
  networking.firewall.extraInputRules = ''
    ip saddr 127.0.0.1 tcp dport 9100 accept
  '';

  # ── Azure Monitor Agent (AMA) ────────────────────────────────────────
  # TODO: the official AMA for Linux is distributed as a VM extension through
  # Azure Resource Manager — it is typically installed by Bicep via the
  # infra/modules/compute module rather than managed in NixOS config.
  # If you prefer a NixOS-native approach, consider using the open-telemetry
  # collector with the Azure Monitor exporter instead.
  #
  # environment.systemPackages = with pkgs; [ opentelemetry-collector ];
}
