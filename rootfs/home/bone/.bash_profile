#
# ~/.bash_profile
#

[[ -f ~/.bashrc ]] && . ~/.bashrc

# Start X11 at login (w/o windows manager)
#[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx
