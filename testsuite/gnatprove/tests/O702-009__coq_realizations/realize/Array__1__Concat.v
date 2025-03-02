(* This file is generated by Why3's Coq-realize driver *)
(* Beware! Only edit allowed sections below    *)
Require Import BuiltIn.
Require BuiltIn.

Require map.Map.
Require Import Psatz.

(* Why3 goal *)
Definition t : Type.
exact Z.
Defined.

(* Why3 goal *)
Definition le : t -> t -> Prop.
exact Z.le.
Defined.

(* Why3 goal *)
Definition lt : t -> t -> Prop.
exact Z.lt.
Defined.

(* Why3 goal *)
Definition gt : t -> t -> Prop.
exact Z.gt.
Defined.

(* Why3 goal *)
Definition add : t -> t -> t.
intros x y; exact (x + y)%Z.
Defined.

(* Why3 goal *)
Definition sub : t -> t -> t.
intros x y; exact (x - y)%Z.
Defined.

(* Why3 goal *)
Definition one : t.
exact (1)%Z.
Defined.

(* Why3 goal *)
Definition component_type : Type.
exact Z.
Defined.

(* Why3 goal *)
Definition map : Type.
exact (map.Map.map t component_type).
Defined.

(* Why3 goal *)
Definition get : map -> t -> component_type.
exact (fun f a => f a).
Defined.

(* Why3 goal *)
Definition concat : map -> t -> t -> map -> t -> t -> map.
intros a af al b bf bl.
exact (fun x => if Zle_bool x al then a x else b ((x - al) + (bf - 1))%Z).
Defined.

(* Why3 goal *)
Lemma concat_def :
  forall (a:map) (b:map),
  forall (a_first:t) (a_last:t) (b_first:t) (b_last:t), forall (i:t),
  (le a_first i /\ le i a_last ->
   ((get (concat a a_first a_last b b_first b_last) i) = (get a i))) /\
  (gt i a_last ->
   ((get (concat a a_first a_last b b_first b_last) i) =
    (get b (add (sub i a_last) (sub b_first one))))).
intros a b a_first a_last b_first b_last i.
unfold concat; unfold sub; unfold add; unfold one;
unfold le; unfold gt; simpl.
split.
 - intros [_ Hi]. unfold get.
   apply Zle_imp_le_bool in Hi; rewrite Hi; auto.
 - intro Hi.
   apply Zgt_not_le in Hi.
   rewrite <- Z.leb_nle in Hi.
   unfold get.
   rewrite Hi; auto.
Qed.

(* Why3 goal *)
Definition concat_singleton_left :
  component_type -> t -> map -> t -> t -> map.
intros a af b bf bl.
exact (fun x => if Zle_bool x af then a else b ((x - af) + (bf - 1))%Z).
Defined.

(* Why3 goal *)
Lemma concat_singleton_left_def :
  forall (a:component_type), forall (b:map),
  forall (a_first:t) (b_first:t) (b_last:t),
  ((get (concat_singleton_left a a_first b b_first b_last) a_first) = a) /\
  (forall (i:t), gt i a_first ->
   ((get (concat_singleton_left a a_first b b_first b_last) i) =
    (get b (add (sub i a_first) (sub b_first one))))).
intros a b a_first b_first b_last.
unfold concat_singleton_left; unfold sub; unfold add;
unfold one; unfold gt; simpl.
split; unfold get.
 - rewrite Z.leb_refl; auto.
 - intros i Hi.
   apply Zgt_not_le in Hi.
   rewrite <- Z.leb_nle in Hi.
   rewrite Hi; auto.
Qed.

(* Why3 goal *)
Definition concat_singleton_right : map -> t -> t -> component_type -> map.
intros a af al b.
exact (fun x => if Zle_bool x al then a x else b).
Defined.

(* Why3 goal *)
Lemma concat_singleton_right_def :
  forall (a:map), forall (b:component_type), forall (a_first:t) (a_last:t),
  ((get (concat_singleton_right a a_first a_last b) (add a_last one)) = b) /\
  (forall (i:t), le a_first i /\ le i a_last ->
   ((get (concat_singleton_right a a_first a_last b) i) = (get a i))).
intros a b a_first a_last.
unfold concat_singleton_right; unfold le;
unfold add; unfold one; simpl.
split; unfold get.
 - assert ((a_last + 1 <=? a_last)%Z = false) by (rewrite Z.leb_nle; lia).
   rewrite H; simpl; auto.
 - intros i [_ Hi].
   apply Zle_imp_le_bool in Hi; rewrite Hi; auto.
Qed.

(* Why3 goal *)
Definition concat_singletons : component_type -> t -> component_type -> map.
intros a af b.
exact (fun x => if Zle_bool x af then a else b).
Defined.

(* Why3 goal *)
Lemma concat_singletons_def :
  forall (a:component_type) (b:component_type), forall (a_first:t),
  ((get (concat_singletons a a_first b) a_first) = a) /\
  ((get (concat_singletons a a_first b) (add a_first one)) = b).
intros a b a_first.
unfold concat_singletons; unfold add; unfold one; simpl.
split; unfold get.
 - rewrite Z.leb_refl; auto.
 - assert ((a_first + 1 <=? a_first)%Z = false) by (rewrite Z.leb_nle; lia).
   rewrite H; simpl; auto.
Qed.

Require map.Const.

(* Why3 goal *)
Definition singleton : component_type -> t -> map.
intros e i.
exact (map.Const.const e).
Defined.

(* Why3 goal *)
Lemma singleton_def :
  forall (v:component_type), forall (i:t), ((get (singleton v i) i) = v).
intros v i.
reflexivity.
Qed.
