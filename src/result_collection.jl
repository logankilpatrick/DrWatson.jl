export collect_results, collect_results!

"""
    collect_results!([filename,] folder; kwargs...) -> df

Search the `folder` (and possibly all subfolders) for new result-files and add
them to `df` which is a `DataFrame` containing all the information from
each result-file.
If a result-file is missing keys that are already columns in `df`,
they will be set as `missing`. If on the other hand new keys are encountered,
a new column will be added and filled with `missing` for all previous entries.

If no file exists in `filename`, then `df` will be saved there. If however
`filename` exists, the existing `df` will be first loaded and then reused.
The reused `df` has some results already collected: files already
included in `df` are skipped in subsequent calls to `collect_results!` while
new result-files are simply appended to the dataframe.

`filename` defaults to:
```julia
filename = joinpath(dirname(folder), "results_\$(basename(folder)).bson")
```

See also [`collect_results`](@ref).

!!! warning
    `df` contains a column `:path` which is the path where each result-file
    is saved to. This is used to not reload and reprocess files already
    present in `df` when searching for new ones.

    If you have an entry `:path` in your saved result-files this will probably
    break `collect_results` (untested).

## Keyword Arguments
* `subfolders::Bool = false` : If `true` also scan all subfolders of `folder`
  for result-files.
* `valid_filetypes = [".bson", ".jld", ".jld2"]`: Only files that have these
  endings are interpreted as result-files. Other files are skipped.
* `verbose = true` : Print (using `@info`) information about the process.
* `white_list` : List of keys to use from result file. By default
  uses all keys from all loaded result-files.
* `black_list = []`: List of keys not to include from result-file.
* `special_list = []`: List of additional (derived) key-value pairs
  to put in `df` as explained below.

`special_list` is a `Vector{Pair{Symbol, Function}}` where each entry
is a derived quantity to be included in `df`. The function entry always
takes a single argument, which is the loaded result-file (a dictionary).
As an example consider that each result-file
contains a field `:longvector` too large to be included in the `df`.
The quantity of interest is the mean and the variance of said field.
To have these values in your results first use `black_list = [:longvector]`
and then define

    special_list = [ :lv_mean => data -> mean(data[:longvector]),
                     :lv_lar  => data -> var(data[:longvector]) ]

In case this operation fails the values will be treated as `missing`.
"""
collect_results!(folder; kwargs...) =
collect_results!(
joinpath(dirname(folder), "results_$(basename(folder)).bson"),
folder; kwargs...)

function collect_results!(filename, folder;
    valid_filetypes = [".bson", "jld", ".jld2"],
    subfolders = false,
    verbose = true,
    newfile = false, # keyword only for defining collect_results without !
    kwargs...)

    if newfile || !isfile(filename)
        !newfile && verbose && @info "Starting a new result collection..."
        df = DataFrames.DataFrame()
    else
        verbose && @info "Loading existing result collection..."
        df = wload(filename)[:df]
    end
    @info "Scanning folder $folder for result files."

    if subfolders
        allfiles = String[]
        for (root, dirs, files) in walkdir(folder)
            for file in files
                push!(allfiles, joinpath(root,file))
            end
        end
    else
        allfiles = joinpath.(Ref(folder), readdir(folder))
    end

    n = 0 # new entries added
    existing_files = :path in names(df) ? df[:,:path] : ()
    for file ∈ allfiles
        is_valid_file(file, valid_filetypes) || continue
        #already added?
        file ∈ existing_files && continue

        data = wload(file)
        df_new = to_data_row(data, file; kwargs...)
        #add filename
        df_new[!, :path] .= file

        df = merge_dataframes!(df, df_new)
        n += 1
    end
    verbose && @info "Added $n entries."
    !newfile && wsave(filename, Dict(:df => df))
    return df
end

"""
    merge_dataframes!(df, df_new) -> merged_df
Merge two dataframes `df` and `df_new`. If the `names` of the dataframes
are the same this is just `vcat`.

If `df_new` is missing keys that are already columns in `df`,
they will set as `missing` in `df`.
If on the other hand new keys are encountered, existing in `df_new`
but not `df`, a new column will be added and filled with `missing`
in `df`. Then `df` and `df_new` are concatenated.
"""
function merge_dataframes!(df1, df2)
    if sort!(names(df1)) == sort!(names(df2))
        return vcat(df1, df2)
    else
        for m ∈ setdiff(names(df1), names(df2))
            df2[!, m] .= [missing]
        end
        for m ∈ setdiff(names(df2), names(df1))
            DataFrames.insertcols!(df1, length(names(df1))+1, m => fill(missing, size(df1,1)))
        end
        return vcat(df1,df2)
    end
end

is_valid_file(file, valid_filetypes) =
    any(endswith(file, v) for v in valid_filetypes)

function to_data_row(data, file;
        white_list = collect(keys(data)),
        black_list = keytype(data)[],
        special_list = keytype(data)[])
    cnames = setdiff!(white_list, black_list)
    df = DataFrames.DataFrame(
        (Symbol.(cnames) .=> (x->[x]).(getindex.(Ref(data),cnames)))...
        )

    #Add special things here
    for (ename, func) in special_list
        try df[!, ename] .= [func(data), ]
        catch e
            @warn "While applying function $(nameof(func)) to file "*
            "$(file), got error $e. Using value `missing` instead."
            df[!, ename] .= [missing, ]
        end
    end
    return df
end

"""
    collect_results(folder; kwargs...) -> df
Do exactly the same as [`collect_results!`](@ref) but don't care to
load (or later save) an existing dataframe. Thus all found results files
are processed.
"""
collect_results(folder; kwargs...) =
collect_results!("", folder; newfile = true, kwargs...)
