use framework "Foundation"
use framework "AppKit"
use scripting additions

on run argv
    if (count of argv) < 1 then
        return "error:no_output_path_provided"
    end if
    
    set base_path to item 1 of argv -- without extension
    
    set pasteboard to current application's NSPasteboard's generalPasteboard()
    set candidate_types to {{current application's NSPasteboardTypePNG, "png"}, {current application's NSPasteboardTypeGIF, "gif"}, {current application's NSPasteboardTypeTIFF, "tiff"}, {current application's NSPasteboardTypeJPEG, "jpg"}, {"public.heic", "heic"}}
    set image_data to missing value
    set file_ext to missing value
    
    repeat with candidate in candidate_types
        set pb_type to item 1 of candidate
        set ext to item 2 of candidate
        
        set data_candidate to pasteboard's dataForType:pb_type
        if data_candidate is not missing value then
            set image_data to data_candidate
            set file_ext to ext
            exit repeat
        end if
    end repeat
    
    if image_data is missing value then
        return "error:no_image_data"
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
