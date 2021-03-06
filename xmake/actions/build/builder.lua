--!The Automatic Cross-platform Build Tool
-- 
-- XMake is free software; you can redistribute it and/or modify
-- it under the terms of the GNU Lesser General Public License as published by
-- the Free Software Foundation; either version 2.1 of the License, or
-- (at your option) any later version.
-- 
-- XMake is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Lesser General Public License for more details.
-- 
-- You should have received a copy of the GNU Lesser General Public License
-- along with XMake; 
-- If not, see <a href="http://www.gnu.org/licenses/"> http://www.gnu.org/licenses/</a>
-- 
-- Copyright (C) 2015 - 2016, ruki All rights reserved.
--
-- @author      ruki
-- @file        builder.lua
--

-- imports
import("core.base.option")
import("core.project.task")
import("core.project.config")
import("core.project.project")
import("core.tool.tool")
import("core.tool.linker")
import("core.tool.compiler")
import("core.project.cache")
import("core.platform.environment")

-- build the object for the *.[o|obj] source file
function _build_object_for_object(target, sourcefile, objectfile, percent)

    -- trace
    print("[%02d%%]: inserting.$(mode) %s", percent, sourcefile)

    -- trace verbose info
    if option.get("verbose") then
        print("cp %s %s", sourcefile, objectfile)
    end

    -- insert this object file
    os.cp(sourcefile, objectfile)
end

-- build the object for the *.[a|lib] source file
function _build_object_for_static(target, sourcefile, objectfile, percent)

    -- trace
    print("[%02d%%]: inserting.$(mode) %s", percent, sourcefile)

    -- trace verbose info
    if option.get("verbose") then
        print("ex %s %s", sourcefile, objectfile)
    end

    -- extract the static library to object directory
    tool.run("ex", sourcefile, path.directory(objectfile))
end

-- build object
function _build_object(target, index)

    -- the object and source files
    local objectfiles = target:objectfiles()
    local sourcefiles = target:sourcefiles()

    -- get the object and source with the given index
    local sourcefile = sourcefiles[index]
    local objectfile = objectfiles[index]

    -- we need not rebuild it if the files are not modified 
    if os.mtime(sourcefile) < os.mtime(objectfile) then
        return 
    end

    -- get the source file type
    local filetype = path.extension(sourcefile):lower()

    -- calculate percent
    local percent = ((_g.targetindex + (index - 1) / #objectfiles) * 100 / _g.targetcount)

    -- build the object for the *.o/obj source makefile
    if filetype == ".o" or filetype == ".obj" then 
        return _build_object_for_object(target, sourcefile, objectfile, percent)
    -- build the object for the *.[a|lib] source file
    elseif filetype == ".a" or filetype == ".lib" then 
        return _build_object_for_static(target, sourcefile, objectfile, percent)
    end

    -- make command
    local command = compiler.compcmd(sourcefile, objectfile, target)

    -- uses ccache
    local ccache = nil
    if config.get("ccache") then
        ccache = tool.shellname("ccache") 
    end
    if ccache then
        command = ccache:append(command, " ")
    end

    -- trace
    print("[%02d%%]: %scompiling.$(mode) %s", percent, ifelse(ccache, "ccache ", ""), sourcefile)

    -- trace verbose info
    if option.get("verbose") then
        print(command)
    end

    -- create directory if not exists
    os.mkdir(path.directory(objectfile))

    -- run cmd with coroutine
    os.corun(command)
end

-- make objects for the given target
function _build_objects(target)

    -- get the max job count
    local jobs = tonumber(option.get("jobs") or "4")

    -- make objects
    local index = 1
    local total = #target:objectfiles()
    local tasks = {}
    repeat

        -- consume tasks
        local pendings = {}
        for i, task in ipairs(tasks) do

            -- get job
            local job = task[1]

            -- get job index
            local job_index = task[2]

            -- pending?
            local status = coroutine.status(job)
            if status ~= "dead" then

                -- resume it
                coroutine.resume(job, job_index)

                -- append the pending task
                table.insert(pendings, task)
            end
        end

        -- update the pending tasks
        tasks = pendings

        -- produce tasks
        while #tasks < jobs and index <= total do
            table.insert(tasks, {coroutine.create(function (index)

                        -- build object
                        _build_object(target, index)

                    end), index})
            index = index + 1
        end

    until #tasks == 0

end

-- build the given target
function _build_target(target)

    -- build objects
    _build_objects(target)

    -- make headers
    local srcheaders, dstheaders = target:headerfiles()
    if srcheaders and dstheaders then
        local i = 1
        for _, srcheader in ipairs(srcheaders) do
            local dstheader = dstheaders[i]
            if dstheader then
                os.cp(srcheader, dstheader)
            end
            i = i + 1
        end
    end

    -- update target index
    _g.targetindex = _g.targetindex + 1

    -- expand object files with *.o/obj
    local objectfiles = {}
    for _, objectfile in ipairs(target:objectfiles()) do
        if objectfile:find("%*") then
            local matchfiles = os.match(objectfile)
            if matchfiles then
                table.join2(objectfiles, matchfiles)
            end
        else
            table.insert(objectfiles, objectfile)
        end
    end

    -- make the command for linking target
    local targetfile    = target:targetfile()
    local command       = linker.linkcmd(objectfiles, targetfile, target)

    -- trace
    print("[%02d%%]: linking.$(mode) %s", _g.targetindex * 100 / _g.targetcount, path.filename(targetfile))

    -- trace verbose info
    if option.get("verbose") then
        print(command)
    end

    -- create directory if not exists
    os.mkdir(path.directory(targetfile))

    -- run command
    os.run(command)
end

-- make the given target 
function _make_target(target)

    -- the target scripts
    local scripts =
    {
        target:get("build_before")
    ,   target:get("build") or _build_target
    ,   target:get("build_after")
    }

    -- run the target scripts
    for i = 1, 3 do
        local script = scripts[i]
        if script ~= nil then
            script(target)
        end
    end
end

-- make the given target and deps
function _make_target_and_deps(target)

    -- this target have been finished?
    if _g.finished[target:name()] then
        return 
    end

    -- make for all dependent targets
    for _, depname in ipairs(target:get("deps")) do
        _make_target_and_deps(project.target(depname)) 
    end

    -- make target
    _make_target(target)

    -- finished
    _g.finished[target:name()] = true
end

-- stats the given target and deps
function _stat_target_count_and_deps(target)

    -- this target have been finished?
    if _g.finished[target:name()] then
        return 
    end

    -- make for all dependent targets
    for _, depname in ipairs(target:get("deps")) do
        _stat_target_count_and_deps(project.target(depname))
    end

    -- update count
    _g.targetcount = _g.targetcount + 1

    -- finished
    _g.finished[target:name()] = true
end

-- stats targets count
function _stat_target_count(targetname)

    -- init finished states
    _g.finished = {}

    -- init targets count
    _g.targetcount = 0

    -- for all?
    if targetname == "all" then

        -- make all targets
        for _, target in pairs(project.targets()) do
            _stat_target_count_and_deps(target)
        end
    else

        -- make target
        _stat_target_count_and_deps(project.target(targetname))
    end
end

-- make
function make(targetname)

    -- enter toolchains environment
    environment.enter("toolchains")

    -- stat targets count
    _stat_target_count(targetname)

    -- clear finished states
    _g.finished = {}

    -- init target index
    _g.targetindex = 0

    -- for all?
    if targetname == "all" then

        -- make all targets
        for _, target in pairs(project.targets()) do
            _make_target_and_deps(target)
        end
    else

        -- make target
        _make_target_and_deps(project.target(targetname))
    end

    -- leave toolchains environment
    environment.leave("toolchains")
end

