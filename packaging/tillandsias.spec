%global repo_owner 8007342
%global repo_name  tillandsias

Name:           tillandsias
Version:        %{version}
Release:        1%{?dist}
Summary:        Development environment manager — tray app
License:        GPL-3.0-or-later
URL:            https://github.com/%{repo_owner}/%{repo_name}

# Source is the pre-built RPM from GitHub Releases.
# COPR Custom source method downloads it via copr-custom-script.sh;
# this URL is informational only.
Source0:        https://github.com/%{repo_owner}/%{repo_name}/releases/download/v%{version}/tillandsias-%{version}-1.x86_64.rpm

# Repackaging spec — we extract the pre-built RPM rather than building
# Rust/Tauri from source (which requires ~30 crates + system libs).
BuildRequires:  cpio
ExclusiveArch:  x86_64
Requires:       podman

# Tauri bundles WebKit; prevent rpmbuild from auto-requiring private .so's
# that live inside the bundle and are not system libraries.
AutoReqProv:    no

%description
Tillandsias is a system tray application that orchestrates development
environments. Right-click the tray icon, pick a project, and a fully
configured environment appears — powered by Podman, invisible to you.

%prep
# Extract the pre-built RPM contents into the build directory
rpm2cpio %{SOURCE0} | cpio -idmv

%install
# Copy extracted tree into the build root
[ -d usr ] && cp -a usr %{buildroot}/usr
[ -d etc ] && cp -a etc %{buildroot}/etc

%files
%{_bindir}/tillandsias-tray
%{_datadir}/applications/tillandsias-tray.desktop
%{_datadir}/icons/hicolor/*/apps/tillandsias-tray.png
