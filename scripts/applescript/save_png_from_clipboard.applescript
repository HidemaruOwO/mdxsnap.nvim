on run argv
    if (count of argv) < 1 then
        return "error:no_output_path_provided"
    end if
    
    set output_path to item 1 of argv
    
    try
        set png_data to (the clipboard as «class PNGf»)
        set png_file to open for access POSIX file output_path with write permission
        write png_data to png_file
        close access png_file
        return "success"
    on error err_msg number err_num
        try
            close access png_file
        end try
        return "error:" & err_msg & ":" & err_num
    end try
end run