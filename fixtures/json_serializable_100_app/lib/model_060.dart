import 'package:json_annotation/json_annotation.dart';

part 'model_060.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model060 {
  const Model060({required this.id, required this.value});

  final int id;
  final String value;

  factory Model060.fromJson(Map<String, dynamic> json) =>
      _$Model060FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model060ToJson(this);
}
