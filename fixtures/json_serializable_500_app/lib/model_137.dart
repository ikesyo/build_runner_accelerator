import 'package:json_annotation/json_annotation.dart';

part 'model_137.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model137 {
  const Model137({required this.id, required this.value});

  final int id;
  final String value;

  factory Model137.fromJson(Map<String, dynamic> json) =>
      _$Model137FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model137ToJson(this);
}
