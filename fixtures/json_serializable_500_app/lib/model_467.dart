import 'package:json_annotation/json_annotation.dart';

part 'model_467.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model467 {
  const Model467({required this.id, required this.value});

  final int id;
  final String value;

  factory Model467.fromJson(Map<String, dynamic> json) =>
      _$Model467FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model467ToJson(this);
}
