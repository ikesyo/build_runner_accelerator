import 'package:json_annotation/json_annotation.dart';

part 'model_167.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model167 {
  const Model167({required this.id, required this.value});

  final int id;
  final String value;

  factory Model167.fromJson(Map<String, dynamic> json) =>
      _$Model167FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model167ToJson(this);
}
