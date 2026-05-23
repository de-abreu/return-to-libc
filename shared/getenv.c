#include <stdio.h>
#include <stdlib.h>

int main(){
  char *shell;
  if ((shell = getenv("MYSHELL"))) {
    printf("%p\n", (void *) shell);
    return EXIT_SUCCESS;
  }
  return EXIT_FAILURE;
}
