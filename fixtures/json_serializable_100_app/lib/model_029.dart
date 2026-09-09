import 'package:json_annotation/json_annotation.dart';

part 'model_029.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model029 {
  const Model029({required this.id, required this.value});

  final int id;
  final String value;

  factory Model029.fromJson(Map<String, dynamic> json) =>
      _$Model029FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model029ToJson(this);
}
