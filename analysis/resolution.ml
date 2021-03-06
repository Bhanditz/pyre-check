(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Pyre

open Ast
open Statement


type global = Annotation.t Node.t
[@@deriving eq, show]


type class_representation = {
  class_definition: Class.t Node.t;
  successors: Type.t list;
  explicit_attributes: Attribute.t Access.SerializableMap.t;
  implicit_attributes: Attribute.t Access.SerializableMap.t;
  is_test: bool;
  methods: Type.t list;
}


type t = {
  annotations: Annotation.t Access.Map.t;
  order: (module TypeOrder.Handler);

  resolve: resolution: t -> Expression.t -> Type.t;
  parse_annotation: Expression.t -> Type.t;

  global: Access.t -> global option;
  module_definition: Access.t -> Module.t option;
  class_definition: Type.t -> (Class.t Node.t) option;
  class_representation: Type.t -> class_representation option;
  constructor: instantiated: Type.t -> resolution: t -> Class.t Node.t -> Type.t;

  parent: Access.t option;
}


let create
    ~annotations
    ~order
    ~resolve
    ~parse_annotation
    ~global
    ~module_definition
    ~class_definition
    ~class_representation
    ~constructor
    ?parent
    () =
  {
    annotations;
    order;
    resolve;
    parse_annotation;
    global;
    module_definition;
    class_definition;
    class_representation;
    constructor;
    parent;
  }


let pp format { annotations; _ } =
  let annotation_map_entry (access, annotation) =
    Format.asprintf
      "%a -> %a"
      Access.pp access
      Annotation.pp annotation;
  in
  Map.to_alist annotations
  |> List.map ~f:annotation_map_entry
  |> String.concat ~sep:", "
  |> Format.fprintf format "[%s]"


let show resolution =
  Format.asprintf "%a" pp resolution


let set_local ({ annotations; _ } as resolution) ~access ~annotation =
  { resolution with annotations = Map.set annotations ~key:access ~data:annotation }


let get_local ?(global_fallback=true) ~access { annotations; global; _ } =
  match Map.find annotations access with
  | Some ({ Annotation.annotation; _ } as result) when not (Type.equal annotation Type.Deleted) ->
      Some result
  | _ when global_fallback ->
      Access.delocalize access
      |> global
      >>| Node.value
  | _ ->
      None


let unset_local ({ annotations; _ } as resolution) ~access =
  { resolution with annotations = Map.remove annotations access }


let annotations { annotations; _ } =
  annotations


let with_annotations resolution ~annotations =
  { resolution with annotations }


let parent { parent; _ } =
  parent


let with_parent resolution ~parent =
  { resolution with parent }


let order { order; _ } =
  order


let resolve ({ resolve; _  } as resolution) =
  resolve ~resolution


let global { global; _ } =
  global


let module_definition { module_definition; _ } =
  module_definition


let class_definition { class_definition; _ } =
  class_definition


let class_representation { class_representation; _ } =
  class_representation


let constructor ({ constructor; _ } as resolution) =
  constructor ~resolution


let function_definitions resolution access =
  let qualifier =
    let rec qualifier ~lead ~tail =
      match tail with
      | head :: tail ->
          let new_lead = lead @ [head] in
          if Option.is_none (module_definition resolution new_lead) then
            lead
          else
            qualifier ~lead:new_lead ~tail
      | _ ->
          lead
    in
    qualifier ~lead:[] ~tail:access
  in
  Ast.SharedMemory.Sources.get_for_qualifier qualifier
  >>| Preprocessing.defines ~include_stubs:true ~include_nested:true


let less_or_equal { order; _ } =
  TypeOrder.less_or_equal order


let join { order; _ } =
  TypeOrder.join order


let meet { order; _ } =
  TypeOrder.meet order


let widen { order; _ } =
  TypeOrder.widen order


let is_instantiated { order; _ } =
  TypeOrder.is_instantiated order


let is_tracked { order; _ } annotation =
  TypeOrder.contains order annotation


let contains_untracked resolution annotation =
  List.exists
    ~f:(fun annotation -> not (is_tracked resolution annotation))
    (Type.elements annotation)


let parse_annotation
    ?(allow_untracked=false)
    ({ parse_annotation; module_definition; _ } as resolution)
    expression =
  let expression =
    let is_local_access =
      Expression.show expression
      |> String.is_substring ~substring:"$local_"
    in
    if is_local_access then
      Expression.delocalize expression
    else
      expression
  in
  let parsed = parse_annotation expression in
  let constraints = function
    | Type.Primitive name ->
        let originates_from_empty_stub =
          name
          |> Access.create
          |> fun access -> Module.from_empty_stub ~access ~module_definition
        in
        if originates_from_empty_stub then
          Some Type.Object
        else
          None
    | _ ->
        None
  in
  let annotation = Type.instantiate parsed ~constraints in
  if contains_untracked resolution annotation && not allow_untracked then
    Type.Top
  else
    annotation


let is_invariance_mismatch { order; _ } ~left ~right =
  match left, right with
  | Type.Parametric { name = left_name; parameters = left_parameters },
    Type.Parametric { name = right_name; parameters = right_parameters }
    when Identifier.equal left_name right_name ->
      let zipped =
        TypeOrder.variables order left
        >>= fun variables ->
        (List.map3
           variables
           left_parameters
           right_parameters
           ~f:(fun variable left right -> (variable, left, right))
         |> function
         | List.Or_unequal_lengths.Ok list -> Some list
         | _ -> None)
      in
      let due_to_invariant_variable (variable, left, right) =
        match variable with
        | Type.Variable { variance = Type.Invariant; _ } ->
            TypeOrder.less_or_equal order ~left ~right
        | _ ->
            false
      in
      zipped
      >>| List.exists ~f:due_to_invariant_variable
      |> Option.value ~default:false
  | _ ->
      false


(* In general, python expressions can be self-referential. This resolution only checks
   literals and annotations found in the resolution map, without resolving expressions. *)
let rec resolve_literal resolution expression =
  let open Ast.Expression in
  match Node.value expression with
  | Access (SimpleAccess access) ->
      begin
        let is_defined class_name =
          class_definition resolution class_name
          |> Option.is_some
        in
        match Expression.Access.name_and_arguments ~call:access with
        | Some { Expression.Access.callee; _ } ->
            let class_name =
              Expression.Access.create callee
              |> Expression.Access.expression
              |> parse_annotation resolution
            in
            if is_defined class_name then
              class_name
            else
              Type.Top
        | None ->
            let class_name = parse_annotation resolution expression in
            (* None is a special type that doesn't have a constructor. *)
            if Type.equal class_name Type.none then
              Type.none
            else if is_defined class_name then
              Type.meta class_name
            else
              Type.Top
      end
  | Await expression ->
      resolve_literal resolution expression
      |> Type.awaitable_value

  | BooleanOperator { BooleanOperator.left; right; _ } ->
      let annotation =
        join
          resolution
          (resolve_literal resolution left)
          (resolve_literal resolution right)
      in
      if Type.is_concrete annotation then annotation else Type.Object

  | Complex _ ->
      Type.complex

  | Dictionary { Dictionary.entries; keywords = [] } ->
      let key_annotation, value_annotation =
        let join_entry (key_annotation, value_annotation) { Dictionary.key; value } =
          (
            join resolution key_annotation (resolve_literal resolution key),
            join resolution value_annotation (resolve_literal resolution value)
          )
        in
        List.fold ~init:(Type.Bottom, Type.Bottom) ~f:join_entry entries
      in
      if Type.is_concrete key_annotation && Type.is_concrete value_annotation then
        Type.dictionary ~key:key_annotation ~value:value_annotation
      else
        Type.Object

  | False ->
      Type.bool

  | Float _ ->
      Type.float

  | Integer _ ->
      Type.integer

  | List elements ->
      let parameter =
        let join sofar element =
          join resolution sofar (resolve_literal resolution element)
        in
        List.fold ~init:Type.Bottom ~f:join elements
      in
      if Type.is_concrete parameter then Type.list parameter else Type.Object

  | Set elements ->
      let parameter =
        let join sofar element =
          join resolution sofar (resolve_literal resolution element)
        in
        List.fold ~init:Type.Bottom ~f:join elements
      in
      if Type.is_concrete parameter then Type.set parameter else Type.Object

  | String { StringLiteral.kind; _ } ->
      begin
        match kind with
        | StringLiteral.Bytes -> Type.bytes
        | _ -> Type.string
      end

  | Ternary { Ternary.target; alternative; _ } ->
      let annotation =
        join
          resolution
          (resolve_literal resolution target)
          (resolve_literal resolution alternative)
      in
      if Type.is_concrete annotation then annotation else Type.Object

  | True ->
      Type.bool

  | Tuple elements ->
      Type.tuple (List.map elements ~f:(resolve_literal resolution))

  | Expression.Yield _ ->
      Type.yield Type.Object

  | _ ->
      Type.Object

let resolve_mutable_literals resolution ~expression ~resolved ~expected =
  match expression with
  | Some { Node.value = Expression.List _; _ }
  | Some { Node.value = Expression.ListComprehension _; _ } ->
      begin
        match resolved, expected with
        | Type.Parametric { name = actual_name; parameters = [actual] },
          Type.Parametric { name = expected_name; parameters = [expected_parameter] }
          when Identifier.equal actual_name "list" &&
               Identifier.equal expected_name "list" &&
               less_or_equal resolution ~left:actual ~right:expected_parameter ->
            expected
        | _ ->
            resolved
      end

  | Some { Node.value = Expression.Set _; _ }
  | Some { Node.value = Expression.SetComprehension _; _ } ->
      begin
        match resolved, expected with
        | Type.Parametric { name = actual_name; parameters = [actual] },
          Type.Parametric { name = expected_name; parameters = [expected_parameter] }
          when Identifier.equal actual_name "set" &&
               Identifier.equal expected_name "set" &&
               less_or_equal resolution ~left:actual ~right:expected_parameter ->
            expected
        | _ ->
            resolved
      end

  | Some { Node.value = Expression.Dictionary _; _ }
  | Some { Node.value = Expression.DictionaryComprehension _; _ } ->
      begin
        match resolved, expected with
        | Type.Parametric { name = actual_name; parameters = [actual_key; actual_value] },
          Type.Parametric {
            name = expected_name;
            parameters = [expected_key; expected_value];
          }
          when Identifier.equal actual_name "dict" &&
               Identifier.equal expected_name "dict" &&
               less_or_equal resolution ~left:actual_key ~right:expected_key &&
               less_or_equal
                 resolution
                 ~left:actual_value
                 ~right:expected_value ->
            expected
        | _ ->
            resolved
      end

  | _ ->
      resolved


let solve_constraints resolution ~constraints ~source ~target =
  let rec solve_constraints_throws resolution ~constraints ~source ~target =
    let solve_all ?(ignore_length_mismatch = false) constraints ~sources ~targets =
      let folded_constraints =
        let solve_pair constraints source target =
          constraints
          >>= (fun constraints -> solve_constraints_throws resolution ~constraints ~source ~target)
        in
        List.fold2 ~init:(Some constraints) ~f:solve_pair sources targets
      in
      match folded_constraints, ignore_length_mismatch with
      | List.Or_unequal_lengths.Ok constraints, _ -> constraints
      | List.Or_unequal_lengths.Unequal_lengths, true -> Some constraints
      | List.Or_unequal_lengths.Unequal_lengths, false -> None
    in
    let source =
      (* This needs to eventually also be in normal less_or_equal, as is, could cause problems with
         variance check *)
      let instantiated_constructor instantiated =
        class_definition resolution instantiated
        >>| constructor resolution ~instantiated
      in
      Option.some_if (Type.is_meta source && Type.is_callable target) source
      >>| Type.single_parameter
      >>= instantiated_constructor
      |> Option.value ~default:source
    in
    match source with
    | Type.Bottom ->
        (* This is needed for representing unbound variables between statements, which can't totally
           be done by filtering because of the promotion done for explicit type variables *)
        Some constraints
    | Type.Union sources ->
        solve_all constraints ~sources ~targets:(List.map sources ~f:(fun _ -> target))
    | _ ->
        if not (Type.is_resolved target) then
          match source, target with
          | _, (Type.Variable { constraints = target_constraints; _ } as variable) ->
              let joined_source =
                let true_join left right =
                  (* Join right now sometimes gives any when it could give a union, we need to
                     avoid that behavior *)
                  let joined = join resolution left right in
                  let unionized = Type.union [left; right] in
                  if not (less_or_equal resolution ~left:joined ~right:unionized) then
                    unionized
                  else
                    joined
                in
                Map.find constraints variable
                >>| (fun existing -> true_join existing source)
                |> Option.value ~default:source
              in
              begin
                match joined_source, target_constraints with
                | Type.Variable { constraints = Type.Explicit source_constraints; _ },
                  Type.Explicit target_constraints ->
                    let exists_in_target_constraints source_constraint =
                      List.exists target_constraints ~f:(Type.equal source_constraint)
                    in
                    Option.some_if
                      (List.for_all source_constraints ~f:exists_in_target_constraints)
                      joined_source
                | Type.Variable { constraints = Type.Bound joined_source; _ },
                  Type.Explicit target_constraints
                | joined_source, Type.Explicit target_constraints ->
                    let in_constraint bound =
                      less_or_equal resolution ~left:joined_source ~right:bound
                    in
                    (* When doing multiple solves, all of these options ought to be considered, *)
                    (* and solved in a fixpoint *)
                    List.find ~f:in_constraint target_constraints
                | _, Type.Bound bound ->
                    Option.some_if
                      (less_or_equal resolution ~left:joined_source ~right:bound)
                      joined_source
                | _, Type.Unconstrained ->
                    Some joined_source
              end
              >>| (fun data -> Map.set constraints ~key:variable ~data)
          | _, Type.Parametric { name = target_name; parameters = target_parameters } ->
              let enforce_variance constraints =
                let instantiated_target =
                  Type.instantiate target ~constraints:(Type.Map.find constraints)
                in
                Option.some_if
                  (less_or_equal resolution ~left:source ~right:instantiated_target)
                  constraints
              in
              begin
                TypeOrder.instantiate_successors_parameters
                  (order resolution)
                  ~source
                  ~target:(Type.Primitive target_name)
                >>= (fun resolved_parameters ->
                    solve_all
                      constraints
                      ~sources:resolved_parameters
                      ~targets:target_parameters)
                >>= enforce_variance
              end
          | Optional source, Optional target
          | source, Optional target
          | Type.Tuple (Type.Unbounded source),
            Type.Tuple (Type.Unbounded target) ->
              solve_constraints_throws resolution ~constraints ~source ~target
          | Type.Tuple (Type.Bounded sources),
            Type.Tuple (Type.Bounded targets) ->
              solve_all constraints ~sources ~targets
          | Type.Tuple (Type.Unbounded source),
            Type.Tuple (Type.Bounded targets) ->
              let sources =
                List.init (List.length targets) ~f:(fun _ -> source)
              in
              solve_all constraints ~sources ~targets
          | Type.Tuple (Type.Bounded sources),
            Type.Tuple (Type.Unbounded target) ->
              solve_constraints_throws resolution ~constraints ~source:(Type.union sources) ~target
          | _, Type.Union targets ->
              (* When doing multiple solves, all of these options ought to be considered, *)
              (* and solved in a fixpoint *)
              List.filter_map targets
                ~f:(fun target -> solve_constraints_throws resolution ~constraints ~source ~target)
              |> List.hd
          | Type.Callable {
              Type.Callable.implementation = {
                Type.Callable.annotation = source;
                parameters = source_parameters;
              };
              _;
            },
            Type.Callable {
              Type.Callable.implementation = {
                Type.Callable.annotation = target;
                parameters = target_parameters;
              };
              _;
            } ->
              let parameter_annotations = function
                | Type.Callable.Defined parameters ->
                    List.map parameters ~f:Type.Callable.Parameter.annotation
                | _ ->
                    []
              in
              solve_constraints_throws resolution ~constraints ~source ~target
              >>= solve_all
                (* Don't ignore previous constraints if encountering a mismatch due to
                 *args/**kwargs vs. concrete parameters or default arguments. *)
                ~ignore_length_mismatch:true
                ~sources:(parameter_annotations source_parameters)
                ~targets:(parameter_annotations target_parameters)
          | _ ->
              None
        else if Type.equal source Type.Top && Type.equal target Type.Object then
          Some constraints
        else if less_or_equal resolution ~left:source ~right:target then
          Some constraints
        else
          None
  in
  (* TODO(T39612118): unwrap this when attributes are safe *)
  try solve_constraints_throws resolution ~constraints ~source ~target
  with TypeOrder.Untracked _ -> None


let constraints_solution_exists ~source ~target resolution =
  solve_constraints resolution ~constraints:Type.Map.empty ~source ~target
  |> Option.is_some
