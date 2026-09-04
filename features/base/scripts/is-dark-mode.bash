# is-dark-mode - exit 0 when the desktop is using a dark colour scheme
#
# macOS reports the setting through `defaults`; on Linux it comes from the
# freedesktop appearance portal, where `uint32 1` is "prefer dark".

case "${OSTYPE}" in
darwin*)
	theme="$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "")"

	[[ ${theme} == "Dark" ]]
	;;

linux*)
	result="$(dbus-send \
		--session \
		--print-reply=literal \
		--reply-timeout=1000 \
		--dest=org.freedesktop.portal.Desktop \
		/org/freedesktop/portal/desktop \
		org.freedesktop.portal.Settings.Read \
		string:org.freedesktop.appearance \
		string:color-scheme)"

	[[ ${result} == *"uint32 1"* ]]
	;;

*)
	echo "Unsupported operating system: ${OSTYPE}" >&2
	exit 1
	;;
esac
