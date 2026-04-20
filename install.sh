#!/bin/bash

# Pastikan script dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo "Tolong jalankan script ini menggunakan root atau sudo."
  exit 1
fi

echo "=============================================="
echo "  AUTO UNINSTALL K8S & SETUP XFCE + WEB VNC   "
echo "=============================================="

# Meminta password di awal sebelum proses tertahan
read -s -p "Buat password untuk akses VNC/Web (Maks 8 Karakter): " VNC_PASS
echo
read -s -p "Ketik ulang password: " VNC_PASS_VERIFY
echo

if [ "$VNC_PASS" != "$VNC_PASS_VERIFY" ]; then
    echo "Error: Password tidak cocok! Script dibatalkan."
    exit 1
fi

echo -e "\n[1/6] Menghapus Kubernetes hingga bersih ke akarnya..."
echo "(Proses ini disembunyikan output-nya agar rapi. Mohon tunggu 1-2 menit)"
# Proses dibungkus dan di-redirect ke /dev/null agar berjalan senyap
(
  kubeadm reset -f
  rm -rf ~/.kube /etc/kubernetes/ /var/lib/kubelet/ /var/lib/etcd/ /var/lib/cni/ /etc/cni/net.d/
  apt-get purge kubeadm kubectl kubelet kubernetes-cni kube* -y
  apt-get autoremove -y
  iptables -F
  iptables -t nat -F
  iptables -t mangle -F
  iptables -X
  crictl rmi --all || true
  crictl rmp -a -f || true
) > /dev/null 2>&1

echo -e "\n[2/6] Memperbarui sistem dan menginstal paket GUI & VNC..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4 xfce4-goodies firefox tigervnc-standalone-server novnc websockify

echo -e "\n[3/6] Mengonfigurasi Password VNC..."
mkdir -p ~/.vnc
echo "$VNC_PASS" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

echo -e "\n[4/6] Mengatur file xstartup untuk XFCE..."
cat <<EOF > ~/.vnc/xstartup
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup

echo -e "\n[5/6] Memulai VNC Server di background..."
# Matikan service jika sudah ada yang berjalan agar port tidak bentrok
vncserver -kill :1 > /dev/null 2>&1 || true
vncserver :1 -localhost no -geometry 1280x720 -depth 24

echo -e "\n[6/6] Memulai Websockify untuk akses HTML5..."
pkill -f "websockify.*6080" || true
websockify --web /usr/share/novnc/ 6080 localhost:5901 &

SERVER_IP=$(hostname -I | awk '{print $1}')

echo "=============================================="
echo "          SETUP SELESAI & BERHASIL!           "
echo "=============================================="
echo "Silakan buka browser Anda dan akses link berikut:"
echo "http://$SERVER_IP:6080/vnc.html"
echo ""
echo "Gunakan password yang baru saja Anda buat untuk login."
echo "NOTE: GUNAKAN PORT FORWARDING KILLERCODA DENGAN PORT 6080"
