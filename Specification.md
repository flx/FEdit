FEdit is a light weight, especially memory light weight text editor with Markdown preview capability and (simple) python, swift and markdown syntax highlighting.

I want the editor window to have three columns:

The left is the folder view. You can open folder and add top level items to the displayed list. There is a search bar at the top, that lets the user filter for files, i.e. if there is '.py AND .swift' it displays all python and swift files, whereby the subfolder is also displayed:

----------------------------
(.py AND .swift)                    <- search bar with standard rounded corners
----------------------------
~/Programming/swift/FEdit           <- top folder added with "File->Open Folder ..." menu
  swift-source/main.swift           <- sub folder, not repeating the opened folder path to keep it short
  python-source/dingdong.py         <- sub folder, not repeating the opened folder path to keep it short

~/Programming/python/project        <- next top folder added with the menu command
----------------------------

The middle column is the verbatim text with a line counter. Lines wrap. Syntax highlighting is here for swift, python and markdown. Only the selected file on the left side is open. When switching files you either have to save before or get asked if you want to save. You can choose 'autosave' so everytime you switch file it autosaves the file.

The middle column becomes 2/3 of the window if the right column doesn't exit, the left column always stays the same. The partitoning can be dragged and is remembered, for next open of the editor.

The right column only exists if the open file is a markdown file. This shows the markdown preview of the open markdown file. Scrolling is synchronized between the textedit view and the markdown view, so the first line appearing in the edit view is the first line shown in the markdown. The sync can be a little approximate, but should be relatively quick. It does'nt have to be instantaneous if this makes a difference.

Overall the aim is to be a memory light editor - I am currently using VS code and it uses 1GB of RAM quite quickly even if the open files are only a couple of kB.


  