import 'package:json_annotation/json_annotation.dart';

part 'model_408.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model408 {
  const Model408({required this.id, required this.value});

  final int id;
  final String value;

  factory Model408.fromJson(Map<String, dynamic> json) =>
      _$Model408FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model408ToJson(this);
}
