try
    return POSIX path of (the clipboard as «class furl»)
on error err_msg_furl number err_num_furl
    try
        return POSIX path of (the clipboard as "public.file-url")
    on error err_msg_public number err_num_public
        try
            set clipboard_text to (the clipboard as text)
            if clipboard_text starts with "/" then
                return clipboard_text
            else
                return "error:furl_public_text_failed:" & err_num_furl & ":" & err_msg_furl & ";" & err_num_public & ":" & err_msg_public
            end if
        on error err_msg_text number err_num_text
            return "error:all_attempts_failed:" & err_num_furl & ":" & err_msg_furl & ";" & err_num_public & ":" & err_msg_public & ";" & err_num_text & ":" & err_msg_text
        end try
    end try
end try