import 'package:json_annotation/json_annotation.dart';

part 'model_017.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model017 {
  const Model017({required this.id, required this.value});

  final int id;
  final String value;

  factory Model017.fromJson(Map<String, dynamic> json) =>
      _$Model017FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model017ToJson(this);
}
