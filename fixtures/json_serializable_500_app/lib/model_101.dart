import 'package:json_annotation/json_annotation.dart';

part 'model_101.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model101 {
  const Model101({required this.id, required this.value});

  final int id;
  final String value;

  factory Model101.fromJson(Map<String, dynamic> json) =>
      _$Model101FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model101ToJson(this);
}
