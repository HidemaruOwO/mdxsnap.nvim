use framework "Foundation"
use framework "AppKit"
use scripting additions

on run argv
    if (count of argv) < 1 then
        return "error:no_output_path_provided"
    end if
    
    set base_path to item 1 of argv -- without extension
    
    set pasteboard to current application's NSPasteboard's generalPasteboard()
    
    -- Prefer GIF first to preserve animation when both GIF and PNG are available
    set candidate_types to {"com.compuserve.gif", "public.gif", "public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif"}
    
    -- Build NSArray of NSString types for availableTypeFromArray
    set ns_strings to {}
    repeat with t in candidate_types
        set end of ns_strings to (current application's NSString's stringWithString:t)
    end repeat
    set ns_array to current application's NSArray's arrayWithArray:ns_strings
    
    set chosen_type to pasteboard's availableTypeFromArray:ns_array
    if chosen_type is missing value then
        return "error:no_supported_type"
    end if
    
    set chosen_type_text to (chosen_type as text)
    try
        set image_data to pasteboard's dataForType:chosen_type
    on error
        set image_data to missing value
    end try
    
    if image_data is missing value then
        return "error:no_image_data_for_" & chosen_type_text
    end if
    
    if chosen_type_text is "com.compuserve.gif" then
        set file_ext to "gif"
    else if chosen_type_text is "public.gif" then
        set file_ext to "gif"
    else if chosen_type_text is "public.tiff" then
        set file_ext to "tiff"
    else if chosen_type_text is "public.jpeg" then
        set file_ext to "jpg"
    else if chosen_type_text is "public.heic" then
        set file_ext to "heic"
    else if chosen_type_text is "public.heif" then
        set file_ext to "heic"
    else
        set file_ext to "png"
    end if
    
    set output_path to base_path & "." & file_ext
    set file_url to current application's |NSURL|'s fileURLWithPath:output_path
    set did_write to image_data's writeToURL:file_url atomically:true
    if did_write as boolean is true then
        return output_path
    else
        return "error:write_failed"
    end if
end run
