local version = function()
  return '0.0.0-ALPHA-DESTRUCTIVE'
end

local license = function()
  local l = [==[Copyright 2024 James Milne

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
may be used to endorse or promote products derived from this software
without specific prior written permission.

***THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS “AS IS”
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.***
  ]==]
  print(l)
  return l
end

if next(arg or {}) ~= nil then
  local info = debug.getinfo(1,'S');
  local _NAME = info.source:sub(2)

  -- Call pandoc, so that we "feel" self-contained.
  local argif = " "
  for idx, v in ipairs(arg) do
    if v == '--license' then
      return license()
    end
    if v == '--version' then
      return version()
    end

    argif = argif .. " " .. string.format('%q', v)
  end
  return os.execute("pandoc --lua-filter " .. _NAME .. argif:sub(2))
else
  -- First pass produces all the metadata we might expect.
  local first_pass = {}
  first_pass.traverse = 'topdown'

  first_pass.Pandoc = function(el)
    if not first_pass._env then
      first_pass._env = {}
      first_pass._env._G = first_pass._env

      -- TODO: Metatable on _env, to allow lookup via a sqlite DB?

      -- Hack print so we can output nicely:
      first_pass._env.stdout = {}
      first_pass._env.print = function(...)
        local stdout = first_pass._env.stdout
        for idx, cell in ipairs({...}) do
          stdout[#stdout + 1] = string.format("> %s", cell)
        end
        return nil
      end

      -- Expose string library:
      first_pass._env.string = {}
      for k, v in pairs(string) do
        first_pass._env['string'][k] = v
      end

      -- TODO: Install default helpers into environment. e.g. math, pairs, ipairs

      first_pass._env['lua'] = function(source)
        local retval = {pcall(load, source, table.concat(PANDOC_STATE.input_files, " "), "t", first_pass._env)}
        if retval[1] then
          return retval[2]()
        else
          return error(retval[2])
        end
      end

      first_pass._env['dump'] = function(_)
        -- TODO: PrettyPrint the entire environment.
        local ret = {}
        for k, v in pairs(first_pass._env) do
          ret[#ret + 1] = string.format("%s = %s", k, v)
        end
        return table.concat(ret, "\n")
      end

      -- TODO: csv -> Table
      -- TODO: json -> PrettyPrinted
      -- TODO: Python, including storing Globals if possible.
      -- TODO: R, including storing Globals if possible.
      -- TODO: C via tcc, including storing Globals if possible.

      -- TODO: Plugin loader...

    end
  end

  first_pass.Meta = function(m)
    if m.date == nil then
      m.date = os.date("%B %e, %Y")
    end

    if m.code_lead == nil then
      m.code_lead = "#!/usr/bin/env "
    end

    return m
  end

  local second_pass = {}
  local third_pass = {}
  second_pass.traverse = 'topdown'
  third_pass.traverse = 'topdown'

  third_pass.CodeBlock = function(el)
    -- TODO: Check if should run
    -- TODO: Run and append output using the below
    local subsystems = {}
    for idx, value in ipairs(el.classes) do
      if value:sub(1, 1) == ':' then
        subsystems[#subsystems+1] = idx
      end
    end
    local runs = {}
    for _, index in ipairs(subsystems) do
      runs[#runs + 1] = el.classes[index]:sub(2)
    end
    local new_classes = {}
    for idx, cell in ipairs(el.classes) do
      local store = true
      for _, index in ipairs(subsystems) do
        if idx == index then
          store = false
          break
        end
      end
      if store then
        new_classes[#new_classes+1] = cell
      end
    end
    el.classes = new_classes

    local r = {el}

    for _, system in ipairs(runs) do
      if first_pass._env[system] then
        local retval = {pcall(first_pass._env[system], el.text)}
        el.text = (third_pass._meta.code_lead or '') .. system .. "\n\n" .. el.text
        local ret_text = table.concat(first_pass._env.stdout, "\n")
        first_pass._env.stdout = {}

        if retval[1] then
          r[#r+1] = pandoc.HorizontalRule()
          r[#r+1] = pandoc.CodeBlock(string.format("%s", ret_text or ''))
          for i=2, #retval do
            -- TODO: Implement a tostring that can handle all this...
            r[#r+1] = pandoc.CodeBlock(string.format('>> %s', retval[i]))
          end
          r[#r+1] = pandoc.HorizontalRule()
        else
          r[#r+1] = pandoc.HorizontalRule()
          r[#r+1] = pandoc.CodeBlock(string.format("%s", ret_text or ''))
          r[#r+1] = pandoc.CodeBlock(string.format('ERROR %q', retval[2]))
          r[#r+1] = pandoc.HorizontalRule()
        end
      else
        -- TODO: Should try pandoc.pipe first.
        el.text = third_pass._meta.code_lead .. system .. "\n\n" .. el.text

        r[#r+1] = pandoc.HorizontalRule()
        r[#r+1] = pandoc.CodeBlock(string.format("%s", ret_text or ''))
        r[#r+1] = pandoc.CodeBlock(string.format('ERROR System %q not implemented.', system))
        r[#r+1] = pandoc.HorizontalRule()
      end
    end

    return r
  end

  third_pass.Str = function(el)
    if el.text:sub(1, 1) == '{' and el.text:sub(-1) == '}' then
      el.text = string.format("%s", first_pass._env[el.text:sub(2, -2)] or el.text)
      return el
    end
  end

  second_pass.Pandoc = function(el)
    third_pass._meta = el.meta
    el.blocks = el.blocks:walk(third_pass)
    return el
  end

  return {
    first_pass,
    second_pass
  }
end
