%global pkgname example

Name:           example
Version:        1.0.0
Release:        %autorelease
Summary:        An example

License:        CC-0
URL:            https://example.org
Source0:        https://example.org/%{name}-%{version}.tar.gz

BuildRequires:  make
%ifarch x86_64
Requires:       bash
%endif

%description
An example spec file


%prep
%autosetup -p1


%build
%configure \
    --prefix=%{_prefix}
%make_build


%install
%make_install


%check
%make_build test


%files
%license LICENSE
%doc README.md
%{_bindir}/example


%changelog
%autochangelog
