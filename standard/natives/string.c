#include <core/error.h>
#include <module.h>
#include <stdio.h>
#include <string.h>
#include <value.h>

Value add_str(int arg_n, Module* mod, Value* args) {
  if (arg_n != 2) THROW("Add expects 2 arguments");
  ASSERT(args[0].type == VALUE_STRING && args[1].type == VALUE_STRING,
         "Add expects string arguments");

  char* new_str =
      malloc(strlen(args[0].string_value) + strlen(args[1].string_value) + 1);
  strcpy(new_str, args[0].string_value);
  strcat(new_str, args[1].string_value);

  return MAKE_STRING(new_str);
}

Value mul_str(int arg_n, Module* mod, Value* args) {
  if (arg_n != 2) THROW("Mul expects 2 arguments");
  ASSERT(args[0].type == VALUE_STRING && args[1].type == VALUE_INT,
         "Mul expects string and integer arguments");

  char* new_str = malloc(strlen(args[0].string_value) * args[1].int_value + 1);
  new_str[0] = '\0';

  for (int i = 0; i < args[1].int_value; i++) {
    strcat(new_str, args[0].string_value);
  }

  return MAKE_STRING(new_str);
}

Value to_string(int arg_n, Module* mod, Value* args) {
  if (arg_n != 1) THROW("To_string expects 1 argument");

  char* new_str = malloc(100);
  switch (args[0].type) {
    case VALUE_INT:
      sprintf(new_str, "%lld", args[0].int_value);
      break;
    case VALUE_FLOAT:
      sprintf(new_str, "%f", args[0].float_value);
      break;
    case VALUE_STRING:
      sprintf(new_str, "\"%s\"", args[0].string_value);
      break;
    case VALUE_LIST:
      sprintf(new_str, "[");
      for (int i = 0; i < args[0].list_value.length; i++) {
        strcat(new_str, args[0].list_value.values[i].string_value);
        if (i < args[0].list_value.length - 1) strcat(new_str, ", ");
      }
      strcat(new_str, "]");
      break;
    case VALUE_ADDRESS:
      sprintf(new_str, "<function 0x%x>", args[0].address_value);
      break;
    case VALUE_NATIVE:
      sprintf(new_str, "<native>");
      break;
    case VALUE_SPECIAL:
      sprintf(new_str, "<special>");
      break;
  }

  return MAKE_STRING(new_str);
}