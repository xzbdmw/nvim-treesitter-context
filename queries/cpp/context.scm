; inherits: c

(for_range_loop
  body: (_ (_) @context.end)
) @context

(class_specifier
  body: (_ (_) @context.end)
) @context

; (access_specifier
;   function_definition: (_ (_) @context.end)
; ) @context

(linkage_specification
  body: (declaration_list (_) @context.end)
) @context
