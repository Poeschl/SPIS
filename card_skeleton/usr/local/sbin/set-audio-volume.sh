#!/bin/sh
# Set every ALSA simple mixer control (Master/PCM/Headphone/Speaker/etc) on
# every detected sound card to 100% and unmuted. This runs before sendspin
# starts so playback is never quietened by a leftover or driver-default
# mixer level, regardless of which card (onboard jack or USB DAC) is used.

for card_path in /proc/asound/card[0-9]*; do
    [ -e "$card_path" ] || continue
    card_num=${card_path##*card}

    amixer -c "$card_num" scontrols 2>/dev/null | awk -F "'" '{print $2}' | while IFS= read -r ctrl; do
        [ -n "$ctrl" ] || continue
        amixer -c "$card_num" sset "$ctrl" 100% unmute >/dev/null 2>&1 || true
    done
done

exit 0
