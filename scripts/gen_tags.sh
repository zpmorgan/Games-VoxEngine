ctags -f tags --recurse --totals \
         --exclude=blib \
         --exclude=.svn \
         --exclude=VoxEngine.c \
         --exclude='*~' \
         --languages=Perl,c --langmap=Perl:+.t \
