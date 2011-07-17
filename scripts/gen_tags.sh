ctags -f tags --recurse --totals \
         --exclude=blib \
         --exclude=.svn \
         --exclude=VoxEngine.c \
         --exclude='*~' \
         --exclude='installed_libs/*' \
         --languages=Perl,c --langmap=Perl:+.t \
