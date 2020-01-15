#include <fmt/format.h>
#include <fmt/ostream.h>
#include <memory>
#include <ostream>
#include <stack>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "parser/common.h"
#include "parser/context.h"
#include "parser/expr.h"
#include "parser/ocaml.h"
#include "parser/stmt.h"
#include "parser/transform.h"
#include "parser/visitor.h"

using fmt::format;
using std::get;
using std::make_unique;
using std::move;
using std::ostream;
using std::stack;
using std::string;
using std::unique_ptr;
using std::unordered_map;
using std::unordered_set;
using std::vector;

#define RETURN(T, ...) (this->result = make_unique<T>(__VA_ARGS__))
template <typename T> T &&setSrcInfo(T &&t, const seq::SrcInfo &i) {
  t->setSrcInfo(i);
  return t;
}

#define E(T, ...) make_unique<T>(__VA_ARGS__)
#define EP(T, ...) setSrcInfo(make_unique<T>(__VA_ARGS__), expr->getSrcInfo())
#define ERROR(...) error(expr->getSrcInfo(), __VA_ARGS__)

ExprPtr TransformExprVisitor::transform(const ExprPtr &expr) {
  TransformExprVisitor v;
  expr->accept(v);
  fmt::print("==> {} :pos {} \n => {} : pos {}\n", expr, expr->getSrcInfo(),
             *v.result, v.result->getSrcInfo());
  return move(v.result);
}
vector<ExprPtr> TransformExprVisitor::transform(const vector<ExprPtr> &exprs) {
  vector<ExprPtr> r(exprs.size());
  for (auto &e : exprs) {
    r.push_back(transform(e));
  }
  return move(r);
}

void TransformExprVisitor::visit(const EmptyExpr *expr) { RETURN(EmptyExpr, ); }
void TransformExprVisitor::visit(const BoolExpr *expr) {
  RETURN(BoolExpr, expr->value);
}
void TransformExprVisitor::visit(const IntExpr *expr) {
  RETURN(IntExpr, expr->value);
}
void TransformExprVisitor::visit(const FloatExpr *expr) {
  RETURN(FloatExpr, expr->value);
}
void TransformExprVisitor::visit(const StringExpr *expr) {
  RETURN(StringExpr, expr->value);
}
void TransformExprVisitor::visit(const FStringExpr *expr) {
  int braces_count = 0, brace_start = 0;
  vector<ExprPtr> items;
  for (int i = 0; i < expr->value.size(); i++) {
    if (expr->value[i] == '{') {
      if (brace_start < i) {
        items.push_back(
            EP(StringExpr, expr->value.substr(brace_start, i - brace_start)));
      }
      if (!braces_count) {
        brace_start = i + 1;
      }
      braces_count++;
    } else if (expr->value[i] == '}') {
      braces_count--;
      if (!braces_count) {
        string code = expr->value.substr(brace_start, i - brace_start);
        auto offset = expr->getSrcInfo();
        offset.col += i;
        items.push_back(transform(parse_expr(code, offset)));
      }
      brace_start = i + 1;
    }
  }
  if (braces_count) {
    ERROR("f-string braces not balanced");
  }
  if (brace_start != expr->value.size()) {
    items.push_back(transform(
        EP(StringExpr,
           expr->value.substr(brace_start, expr->value.size() - brace_start))));
  }
  this->result = transform(
      EP(CallExpr, EP(DotExpr, EP(IdExpr, "str"), "cat"), move(items)));
}
void TransformExprVisitor::visit(const KmerExpr *expr) {
  this->result =
      transform(EP(CallExpr,
                   EP(IndexExpr, EP(IdExpr, "Kmer"),
                      EP(IntExpr, std::to_string(expr->value.size()), "")),
                   EP(SeqExpr, expr->value)));
}
void TransformExprVisitor::visit(const SeqExpr *expr) {
  if (expr->prefix == "p") {
    this->result =
        transform(EP(CallExpr, EP(IdExpr, "seq"), EP(StringExpr, expr->value)));
  } else if (expr->prefix == "s") {
    RETURN(SeqExpr, expr->value, expr->prefix);
  } else {
    ERROR("invalid seq prefix '{}'", expr->prefix);
  }
}
void TransformExprVisitor::visit(const IdExpr *expr) { RETURN(IdExpr, expr); }
void TransformExprVisitor::visit(const UnpackExpr *expr) {
  ERROR("unexpected unpacking operator");
}
void TransformExprVisitor::visit(const TupleExpr *expr) {
  RETURN(TupleExpr, transform(expr->items));
}
void TransformExprVisitor::visit(const ListExpr *expr) {
  RETURN(ListExpr, transform(expr->items));
}
void TransformExprVisitor::visit(const SetExpr *expr) {
  RETURN(SetExpr, transform(expr->items));
}
void TransformExprVisitor::visit(const DictExpr *expr) {
  vector<DictExpr::KeyValue> items;
  for (auto &l : expr->items) {
    items.push_back({transform(l.key), transform(l.value)});
  }
  RETURN(DictExpr, move(items));
}
void TransformExprVisitor::visit(const GeneratorExpr *expr) {
  vector<GeneratorExpr::Body> loops;
  for (auto &l : expr->loops) {
    loops.push_back({l.vars, transform(l.gen), transform(l.conds)});
  }
  RETURN(GeneratorExpr, expr->kind, transform(expr->expr), move(loops));
  /* TODO transform: T = list[T]() for_1: cond_1: for_2: cond_2: expr */
}
void TransformExprVisitor::visit(const DictGeneratorExpr *expr) {
  vector<GeneratorExpr::Body> loops;
  for (auto &l : expr->loops) {
    loops.push_back({l.vars, transform(l.gen), transform(l.conds)});
  }
  RETURN(DictGeneratorExpr, transform(expr->key), transform(expr->expr),
         move(loops));
}
void TransformExprVisitor::visit(const IfExpr *expr) {
  RETURN(IfExpr, transform(expr->cond), transform(expr->eif),
         transform(expr->eelse));
}
void TransformExprVisitor::visit(const UnaryExpr *expr) {
  RETURN(UnaryExpr, expr->op, transform(expr->expr));
}
void TransformExprVisitor::visit(const BinaryExpr *expr) {
  RETURN(BinaryExpr, transform(expr->lexpr), expr->op, transform(expr->rexpr));
}
void TransformExprVisitor::visit(const PipeExpr *expr) {
  vector<PipeExpr::Pipe> items;
  for (auto &l : expr->items) {
    items.push_back({l.op, transform(l.expr)});
  }
  RETURN(PipeExpr, move(items));
}
void TransformExprVisitor::visit(const IndexExpr *expr) {
  RETURN(IndexExpr, transform(expr->expr), transform(expr->index));
}
void TransformExprVisitor::visit(const CallExpr *expr) {
  // TODO: name resolution should come here!
  vector<CallExpr::Arg> args;
  for (auto &i : expr->args) {
    args.push_back({i.name, transform(i.value)});
  }
  RETURN(CallExpr, transform(expr->expr), move(args));
}
void TransformExprVisitor::visit(const DotExpr *expr) {
  RETURN(DotExpr, transform(expr->expr), expr->member);
}
void TransformExprVisitor::visit(const SliceExpr *expr) {
  string prefix;
  if (!expr->st && expr->ed) {
    prefix = "l";
  } else if (expr->st && !expr->ed) {
    prefix = "r";
  } else if (!expr->st && expr->ed) {
    prefix = "e";
  }
  if (expr->step) {
    prefix += "s";
  }
  vector<ExprPtr> args;
  if (expr->st) {
    args.push_back(transform(expr->st));
  }
  if (expr->ed) {
    args.push_back(transform(expr->ed));
  }
  if (expr->step) {
    args.push_back(transform(expr->step));
  }
  if (!args.size()) {
    args.push_back(transform(EP(IntExpr, "0")));
  }
  // TODO: might need transform later
  this->result = EP(CallExpr, EP(IdExpr, prefix + "slice"), move(args));
}
void TransformExprVisitor::visit(const EllipsisExpr *expr) {
  RETURN(EllipsisExpr, );
}
void TransformExprVisitor::visit(const TypeOfExpr *expr) {
  RETURN(TypeOfExpr, transform(expr->expr));
}
void TransformExprVisitor::visit(const PtrExpr *expr) {
  RETURN(PtrExpr, transform(expr->expr));
}
void TransformExprVisitor::visit(const LambdaExpr *expr) { ERROR("TODO"); }
void TransformExprVisitor::visit(const YieldExpr *expr) { RETURN(YieldExpr, ); }