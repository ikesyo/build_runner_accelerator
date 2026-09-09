import 'package:json_annotation/json_annotation.dart';

part 'model_302.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model302 {
  const Model302({required this.id, required this.value});

  final int id;
  final String value;

  factory Model302.fromJson(Map<String, dynamic> json) =>
      _$Model302FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model302ToJson(this);
}
