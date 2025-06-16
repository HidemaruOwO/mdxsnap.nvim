on run argv
    if (count of argv) < 1 then
        return "error:no_output_path_provided"
    end if
    
    set output_path to item 1 of argv
    
    try
        set tiff_data to (the clipboard as «class TIFF»)
        set tiff_file to open for access POSIX file output_path with write permission
        write tiff_data to tiff_file
        close access tiff_file
        return "success"
    on error err_msg number err_num
        try
            close access tiff_file
        end try
        return "error:" & err_msg & ":" & err_num
    end try
end run