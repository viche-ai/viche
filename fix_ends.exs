# Fix InboxController
content = File.read!("lib/viche_web/controllers/inbox_controller.ex")

content =
  String.replace(
    content,
    "            end\n        end\n    end\n  end",
    "            end\n        end\n    end\n  end"
  )

# Wait, let's just format the file and see if it compiles.
# Actually, let's just rewrite the function.
