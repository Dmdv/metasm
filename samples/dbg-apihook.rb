#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2006-2009 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


#
# This sample defines an ApiHook class, that you can subclass to easily hook functions
# in a debugged process. Your custom function will get called whenever an API function is,
# giving you access to the arguments, you can also take control just before control returns
# to the caller.
# See the example in the end for more details.
# As a standalone application, it hooks WriteFile in the 'notepad' process, and make it
# skip the first two bytes of the buffer.
#

require 'metasm'

class ApiHook
	# rewrite this function to list the hooks you want
	# return an array of hashes
	def setup
		#[{ :function => 'WriteFile', :abi => :stdcall },	# standard function hook
		# { :module => 'Foo.dll', :rva => 0x2433,		# arbitrary code hook
		#   :abi => :fastcall, :hookname => 'myhook' }]		# hooks named pre_myhook/post_myhook
	end

	# initialized from a Debugger or a process description that will be debugged
	# sets the hooks up, then run_forever
	def initialize(dbg)
		if not dbg.kind_of? Metasm::Debugger
			process = Metasm::OS.current.find_process(dbg)
			raise 'no such process' if not process
			dbg = process.debugger
		end
		dbg.loadallsyms
		@dbg = dbg
		setup.each { |h| setup_hook(h) }
		init_prerun if respond_to?(:init_prerun)	# allow subclass to do stuff before main loop
		@dbg.run_forever
	end

	# setup one function hook
	def setup_hook(h)
		pre  =  "pre_#{h[:hookname] || h[:function]}"
		post = "post_#{h[:hookname] || h[:function]}"

		@nargs = h[:nargs] || method(pre).arity if respond_to?(pre)

		if target = h[:address]
		elsif target = h[:rva]
			modbase = @dbg.modulemap[h[:module]]
			raise "cant find module #{h[:module]} in #{@dbg.modulemap.join(', ')}" if not modbase
			target += modbase[0]
		else
			target = h[:function]
		end

		@dbg.bpx(target) {
			catch(:finish) {
				if respond_to? pre
					@cur_abi = h[:abi]
					args = read_arglist
					send pre, *args
				end
				if respond_to? post
					@dbg.bpx(@dbg.func_retaddr, true) {
						send post, @dbg.func_retval
					}
				end
			}
		}
	end

	# retrieve the arglist at func entry, from @nargs & @cur_abi
	def read_arglist
		nr = @nargs
		args = []

		if (@cur_abi == :fastcall or @cur_abi == :thiscall) and nr > 0
			args << @dbg.get_reg_value(:ecx)
			nr -= 1
		end

		if @cur_abi == :fastcall and nr > 0
			args << @dbg.get_reg_value(:edx)
			nr -= 1
		end

		nr.times { |i| args << @dbg.func_arg(i) }

		args
       	end

	# patch the value of an argument
	# only valid in pre_hook
	# nr starts at 0
	def patch_arg(nr, value)
		case @cur_abi
		when :fastcall
			case nr
			when 0
				@dbg.set_reg_value(:ecx, value)
				return
			when 1
				@dbg.set_reg_value(:edx, value)
				return
			else
				nr -= 2
			end
		when :thiscall
			case nr
			when 0
				@dbg.set_reg_value(:ecx, value)
				return
			else
				nr -= 1
			end
		end

		@dbg.func_arg_set(nr, value)
	end

	# patch the function return value
	# only valid post_hook
	def patch_ret(val)
		if false and ret_ia32_longlong
			@dbg.set_reg_value(:edx, (val >> 32) & 0xffffffff)
			val &= 0xffffffff
		end
		@dbg.func_retval_set(val)
	end

	# skip the function call
	# only valid in pre_hook
	def finish(retval)
		patch_ret(retval)
		@dbg.ip = @dbg.cpu.dbg_retaddr
		case @cur_abi
		when :fastcall
			@dbg.sp += 4*(@nargs-2) if @nargs > 2
		when :thiscall
			@dbg.sp += 4*(@nargs-1) if @nargs > 1
		when :stdcall
			@dbg.sp += 4*@nargs
		end
		@dbg.sp += @dbg.cpu.sz/8
		throw :finish
	end
end



if __FILE__ == $0

class MyHook < ApiHook
	def setup
		[{ :function => 'WriteFile', :abi => :stdcall }]
	end

	def init_prerun
		puts "hooks ready, save a file in notepad"
	end

	def pre_WriteFile(handle, pbuf, size, pwritten, overlap)
		# we can skip the function call with this
		#finish(28)

		puts "writing #{@dbg.memory[pbuf, size].inspect}"

		# skip first 2 bytes of the buffer
		patch_arg(1, pbuf+2)
		patch_arg(2, size-2)
		# save values for post_hook
		@size = size
		@pwritten = pwritten
	end

	def post_WriteFile(retval)
		# we can patch the API return value with this
		#patch_retval(42)

		# retrieve NumberOfBytesWritten
		written = @dbg.memory_read_int(@pwritten)
		if written == @size
			# if written everything, patch the value so that the program dont detect our intervention
			@dbg.memory_write_int(@pwritten, written+2)
		end

		puts "write retval: #{retval}, written: #{written}"
	end
end

# name says it all
Metasm::WinOS.get_debug_privilege

# run our Hook engine on a running 'notepad' instance
MyHook.new('notepad')

end