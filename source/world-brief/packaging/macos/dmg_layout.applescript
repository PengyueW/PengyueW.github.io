-- Arranges the disk image window: our background, no toolbar, the app on the left and the
-- Applications shortcut on the right, exactly where the arrow in the background points.
on run argv
	set volName to item 1 of argv
	set bgFile to item 2 of argv
	tell application "Finder"
		tell disk volName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			-- 660 x 420 of content, plus the title bar Finder counts inside the bounds.
			set the bounds of container window to {380, 120, 1040, 563}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 128
			set text size of viewOptions to 13
			set label position of viewOptions to bottom
			set background picture of viewOptions to file (".background:" & bgFile)
			set position of item "World Brief.app" of container window to {170, 215}
			set position of item "Applications" of container window to {490, 215}
			-- Anything else in the window would only be clutter.
			try
				set position of item ".background" of container window to {900, 900}
				set position of item ".VolumeIcon.icns" of container window to {900, 900}
			end try
			update without registering applications
			delay 2
			close
		end tell
	end tell
end run
