import 'package:json_annotation/json_annotation.dart';

part 'model_300.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model300 {
  const Model300({required this.id, required this.value});

  final int id;
  final String value;

  factory Model300.fromJson(Map<String, dynamic> json) =>
      _$Model300FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model300ToJson(this);
}
